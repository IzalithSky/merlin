class_name WorldCharacterSpawner
extends Node3D

const PLAYER_CHARACTER_SCENE := preload("res://scenes/player_character.tscn")
const PLANE_CHARACTER_SCENE := preload("res://scenes/plane_character.tscn")
const DISPLAY_SETTINGS_APPLIER := preload("res://scripts/display_settings_applier.gd")
const LOCAL_PLANE_PRESENTATION_BINDING := preload("res://scripts/local_plane_presentation_binding.gd")
const NET_METRICS_SCRIPT := preload("res://scripts/net_metrics.gd")
const NET_WIRE := preload("res://scripts/net_wire.gd")
const PLANE_BOT_SETUP := preload("res://scripts/plane_bot_setup.gd")
const CHARACTER_NAME_PREFIX := "PlayerCharacter_"
const BOT_PEER_ID_BASE := 1000000

enum CharacterType {
	CAMERA_CUBE,
	PLANE,
}

@export var spawn_center := Vector3.ZERO
@export var spawn_height_offset: float = 1500.0
@export var spawn_radius := 480.0
@export var late_join_spawn_min_radius := 300.0
@export var late_join_spawn_max_radius := 600.0
@export var character_type := CharacterType.PLANE
@export var bot_count := 1
@export var bot_team_ids: PackedInt32Array = []
@export var bot_spawn_radius := 2400.0
@export var bot_parallel_separation: float = 1000.0
@export var bot_follow_target_path: NodePath = NodePath("level/BotFollowTarget")
@export var bot_player_killzone_distance := 250.0
@export var bot_player_killzone_tolerance := 150.0
@export var server_net_tick_hz: float = 30.0
@export var packet_budget_pkts_per_sec: float = 35.0
@export var net_metrics_enabled := false
@export var net_metrics_print_summary := false
@onready var _characters: Node3D = $characters
@onready var _projectiles: Node3D = $projectiles
@onready var _target_registry = $TargetRegistry
@onready var _projectile_net = $ProjectileNetReplicator
@onready var _health_net = $HealthNetReplicator

var _peer_spawn_states: Dictionary = {}
var _bot_peer_ids: Dictionary = {}
var _world_ready_peers: Dictionary = {}
var _spawn_random := RandomNumberGenerator.new()
var _bot_follow_target: Node3D
var _local_plane_presentation
var _server_aero_payload: Dictionary = {}
var _client_aero_payload: Dictionary = {}
var _net_metrics := NET_METRICS_SCRIPT.new()
var _net_metrics_print_accumulator := 0.0
var _world_snapshot_tick := 0
var _world_snapshot_accumulator := 0.0
var _packet_budget_warning_active := false


func _ready() -> void:
	add_to_group("world_character_spawner")
	_spawn_random.randomize()
	_local_plane_presentation = LOCAL_PLANE_PRESENTATION_BINDING.new(self)
	_projectile_net.configure(self, _projectiles)
	_health_net.configure(self)
	_resolve_bot_follow_target()
	_apply_lobby_bot_count_override()
	DisplaySettings.settings_changed.connect(_on_display_settings_changed)

	if multiplayer.multiplayer_peer == null:
		if bot_count < 1:
			bot_count = 1

		var spawn_state := _build_radial_spawn_state(0, 1)
		_peer_spawn_states[1] = spawn_state
		_spawn_character(1, true, spawn_state["character_position"], spawn_state["yaw"])
		_spawn_single_player_bots(spawn_state)
		return

	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_world_ready_peers[multiplayer.get_unique_id()] = true
		_register_initial_peers()
		_spawn_registered_characters_locally()
		_spawn_bots(true)
	else:
		call_deferred("_request_world_sync")


func _process(delta: float) -> void:
	_tick_world_snapshot_broadcast(delta)

	if not net_metrics_enabled or not net_metrics_print_summary:
		return

	_net_metrics_print_accumulator += delta
	if _net_metrics_print_accumulator < 1.0:
		return

	_net_metrics_print_accumulator = 0.0
	_check_packet_budget()
	print("net_metrics %s" % get_net_metrics_summary_text())


func _tick_world_snapshot_broadcast(delta: float) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	var tick_hz := maxf(server_net_tick_hz, 0.001)
	_world_snapshot_accumulator += delta
	var tick_interval := 1.0 / tick_hz
	while _world_snapshot_accumulator >= tick_interval:
		_world_snapshot_accumulator -= tick_interval
		_broadcast_world_snapshot()


static func find_in_tree(from_node: Node):
	var current: Node = from_node
	while current != null:
		if current.is_in_group("world_character_spawner"):
			return current
		current = current.get_parent()

	var tree := from_node.get_tree()
	if tree == null:
		return null

	var candidates := tree.get_nodes_in_group("world_character_spawner")
	if candidates.is_empty():
		return null
	return candidates[0]


func _apply_lobby_bot_count_override() -> void:
	var lobby := get_node_or_null("/root/Lobby")
	if lobby == null:
		return

	var configured_bot_count: Variant = lobby.get("bot_count")
	if configured_bot_count == null:
		return

	bot_count = maxi(int(configured_bot_count), 0)


func _register_initial_peers() -> void:
	var peer_ids := _get_lobby_peer_ids()
	var server_peer_id := multiplayer.get_unique_id()
	if not peer_ids.has(server_peer_id):
		peer_ids.append(server_peer_id)

	peer_ids.sort()
	var player_count := peer_ids.size()
	for index in range(player_count):
		var peer_id: int = peer_ids[index]
		if not _peer_spawn_states.has(peer_id):
			_peer_spawn_states[peer_id] = _build_radial_spawn_state(index, player_count)


func _register_peer(peer_id: int) -> bool:
	if _peer_spawn_states.has(peer_id):
		return false

	_peer_spawn_states[peer_id] = _build_late_join_spawn_state()
	return true


func _spawn_bots(broadcast_to_clients: bool) -> void:
	if bot_count <= 0:
		return

	var resolved_bot_count: int = max(bot_count, 0)
	for bot_index in range(resolved_bot_count):
		var bot_peer_id := BOT_PEER_ID_BASE + bot_index
		if _peer_spawn_states.has(bot_peer_id):
			continue

		var bot_spawn_state := _build_bot_spawn_state(bot_index, resolved_bot_count)
		_peer_spawn_states[bot_peer_id] = bot_spawn_state
		_bot_peer_ids[bot_peer_id] = true
		_spawn_character(
			bot_peer_id,
			false,
			bot_spawn_state["character_position"],
			bot_spawn_state["yaw"]
		)

		if broadcast_to_clients and multiplayer.multiplayer_peer != null and multiplayer.is_server():
			_broadcast_spawn_state(bot_peer_id, -1)


func _spawn_single_player_bots(player_spawn_state: Dictionary) -> void:
	if bot_count <= 0:
		return

	var player_pos: Vector3 = player_spawn_state["character_position"]
	var player_yaw: float = player_spawn_state["yaw"]
	var player_right := Vector3(cos(player_yaw), 0.0, -sin(player_yaw))

	var resolved_bot_count: int = maxi(bot_count, 0)
	for bot_index in range(resolved_bot_count):
		var bot_peer_id := BOT_PEER_ID_BASE + bot_index
		if _peer_spawn_states.has(bot_peer_id):
			continue

		var bot_position := player_pos + player_right * bot_parallel_separation * float(bot_index + 1)
		var bot_spawn_state := {"character_position": bot_position, "yaw": player_yaw}
		_peer_spawn_states[bot_peer_id] = bot_spawn_state
		_bot_peer_ids[bot_peer_id] = true
		_spawn_character(bot_peer_id, false, bot_position, player_yaw)


func _resolve_bot_follow_target() -> void:
	_bot_follow_target = null
	if bot_follow_target_path.is_empty():
		return

	_bot_follow_target = get_node_or_null(bot_follow_target_path) as Node3D


func _configure_bot_behavior(character: Node3D, peer_id: int) -> void:
	if character == null or character_type != CharacterType.PLANE:
		return

	var bot_peer := _is_bot_peer(peer_id)
	var bot_active := bot_peer and (multiplayer.multiplayer_peer == null or multiplayer.is_server())

	if _bot_follow_target == null:
		_resolve_bot_follow_target()

	PLANE_BOT_SETUP.configure_plane(
		character,
		bot_peer,
		bot_active,
		_bot_follow_target,
		bot_player_killzone_distance,
		bot_player_killzone_tolerance
	)

	if bot_peer and character.has_method("apply_default_aero_tables"):
		character.call("apply_default_aero_tables")
	var bot_index := peer_id - BOT_PEER_ID_BASE
	if bot_peer and bot_index >= 0 and bot_index < bot_team_ids.size():
		character.team_id = bot_team_ids[bot_index]


func _is_bot_peer(peer_id: int) -> bool:
	return _bot_peer_ids.has(peer_id)


func _spawn_character(peer_id: int, local_player: bool, character_position: Vector3, yaw: float) -> Node3D:
	var existing := _characters.get_node_or_null(_character_name(peer_id)) as Node3D
	if existing != null:
		if character_type == CharacterType.PLANE:
			var existing_plane := existing
			existing_plane.set_server_net_tick_hz(server_net_tick_hz)
			existing_plane.configure(peer_id, local_player)
			_set_character_local_binding(existing_plane, local_player)
			_configure_bot_behavior(existing_plane, peer_id)
			_register_lockable_target(existing_plane)
			_health_net.bind_character(existing_plane, peer_id)
			_apply_display_settings_to_character(existing_plane)
			_apply_client_aero_tables_to_character(existing_plane)
			if local_player:
				_bind_local_plane_presentation(existing_plane)
		else:
			var existing_player := existing
			existing_player.configure(peer_id, local_player)
			_set_character_local_binding(existing_player, local_player)
		return existing

	var character := _get_character_scene().instantiate() as Node3D
	character.name = _character_name(peer_id)
	character.position = character_position
	character.rotation.y = yaw
	character.configure(peer_id, local_player)
	_characters.add_child(character, true)
	if character is RigidBody3D:
		(character as RigidBody3D).linear_velocity = -character.basis.z * 100.0

	if character_type == CharacterType.PLANE:
		var plane := character
		plane.set_server_net_tick_hz(server_net_tick_hz)
		_set_character_local_binding(plane, local_player)
		_configure_bot_behavior(plane, peer_id)
		_register_lockable_target(plane)
		_health_net.bind_character(plane, peer_id)
		_apply_display_settings_to_character(plane)
		_apply_client_aero_tables_to_character(plane)
		if local_player:
			_bind_local_plane_presentation(plane)
	else:
		var player_character := character
		_set_character_local_binding(player_character, local_player)
	return character


func _despawn_character(peer_id: int) -> void:
	var is_local_character := false
	if multiplayer.multiplayer_peer == null:
		is_local_character = peer_id == 1
	else:
		is_local_character = peer_id == multiplayer.get_unique_id()

	var character := _characters.get_node_or_null(_character_name(peer_id))
	if character != null:
		_unregister_lockable_target(character)
		character.queue_free()

	if is_local_character:
		_clear_local_plane_presentation_target()


func _character_name(peer_id: int) -> String:
	return "%s%d" % [CHARACTER_NAME_PREFIX, peer_id]


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return

	_despawn_character(peer_id)
	_peer_spawn_states.erase(peer_id)
	_world_ready_peers.erase(peer_id)
	_broadcast_despawn(peer_id)


func _on_local_character_input_produced(_peer_id: int, input: PackedByteArray) -> void:
	if multiplayer.multiplayer_peer == null or multiplayer.is_server():
		return

	record_net_send("input", input)
	sv_submit_input.rpc_id(1, input)


func _request_world_sync() -> void:
	if multiplayer.multiplayer_peer == null or multiplayer.is_server():
		return

	record_net_send("spawn", [])
	request_world_sync.rpc_id(1)


@rpc("any_peer", "reliable")
func request_world_sync() -> void:
	if not multiplayer.is_server():
		return

	record_net_recv("spawn", [])
	var sender_id := multiplayer.get_remote_sender_id()
	var is_new_peer := _register_peer(sender_id)
	_world_ready_peers[sender_id] = true
	# Tables go out before the spawn sync on the same reliable channel, so the
	# peer's planes are configured with the server's flight model on spawn.
	_send_aero_tables_to_peer(sender_id)
	_spawn_peer_character_locally(sender_id)
	_sync_spawn_states_to_peer(sender_id)

	if is_new_peer:
		_broadcast_spawn_state(sender_id, sender_id)


func _send_aero_tables_to_peer(target_peer_id: int) -> void:
	_capture_server_aero_payload()
	if _server_aero_payload.is_empty():
		return

	record_net_send("spawn", _server_aero_payload)
	cl_apply_aero_tables.rpc_id(target_peer_id, _server_aero_payload)


func _capture_server_aero_payload() -> void:
	if not _server_aero_payload.is_empty():
		return

	# Any server-side plane carries the effective tables (scene defaults plus the
	# server's user:// override, post-sanitize); they are identical across planes.
	for character in _characters.get_children():
		var plane_character := character as PlaneCharacter
		if plane_character != null:
			_server_aero_payload = plane_character.get_aero_tables_payload()
			return


@rpc("authority", "reliable")
func cl_apply_aero_tables(payload: Dictionary) -> void:
	if multiplayer.is_server():
		return

	record_net_recv("spawn", payload)
	_client_aero_payload = payload.duplicate(true)
	for character in _characters.get_children():
		var plane_character := character as PlaneCharacter
		if plane_character != null:
			plane_character.apply_aero_tables_payload(_client_aero_payload)


@rpc("authority", "reliable")
func spawn_character(peer_id: int, character_position: Vector3, yaw: float) -> void:
	record_net_recv("spawn", [peer_id, character_position, yaw])
	_spawn_character(peer_id, _is_local_peer(peer_id), character_position, yaw)
	_enforce_local_ownership()


@rpc("authority", "reliable")
func despawn_character(peer_id: int) -> void:
	record_net_recv("spawn", [peer_id])
	_despawn_character(peer_id)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func sv_submit_input(input: PackedByteArray) -> void:
	if not multiplayer.is_server():
		return

	record_net_recv("input", input)
	var decoded_input := NET_WIRE.decode_input(input)
	if decoded_input.is_empty():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var plane_character := _characters.get_node_or_null(_character_name(sender_id)) as PlaneCharacter
	if plane_character == null or not is_instance_valid(plane_character):
		return
	if plane_character.is_shot_down:
		return
	if not _is_valid_input_packet(decoded_input):
		return
	plane_character.apply_net_control_input(decoded_input)


func _is_valid_input_packet(input: Dictionary) -> bool:
	if int(input.get("seq", -1)) < 0:
		return false
	for axis_key in ["roll", "pitch", "yaw", "throttle", "effective_pitch"]:
		var value: Variant = input.get(axis_key)
		if not (value is float or value is int):
			return false
		if not is_finite(float(value)):
			return false
	for bool_key in [
		"pitch_control_active",
		"yaw_control_active",
		"direct_roll_control_active",
		"relative_roll_target_active",
		"pitch_assist_enabled",
		"stabilization_assist_enabled",
		"sustain_turn_mode_active",
	]:
		if input.has(bool_key) and not (input.get(bool_key) is bool):
			return false
	return true


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func apply_world_snapshot(world_snapshot: PackedByteArray) -> void:
	record_net_recv("state", world_snapshot)
	var decoded_snapshot := NET_WIRE.decode_world_snapshot(world_snapshot)
	if decoded_snapshot.is_empty():
		return
	var planes: Array = decoded_snapshot.get("planes", [])
	for snapshot_variant in planes:
		if not snapshot_variant is Dictionary:
			continue
		var snapshot: Dictionary = snapshot_variant
		var peer_id := int(snapshot.get("peer_id", -1))
		if peer_id < 0:
			continue
		var character := _characters.get_node_or_null(_character_name(peer_id))
		if character == null:
			continue

		if peer_id == multiplayer.get_unique_id():
			var plane_character := character as PlaneCharacter
			if plane_character != null:
				plane_character.apply_authoritative_state(snapshot)
			continue

		character.apply_remote_state(snapshot)


func _spawn_registered_characters_locally() -> void:
	for peer_id in _sorted_peer_ids():
		_spawn_peer_character_locally(peer_id)


func _spawn_peer_character_locally(peer_id: int) -> void:
	if not _peer_spawn_states.has(peer_id):
		return

	var spawn_state: Dictionary = _peer_spawn_states[peer_id]
	var character_position: Vector3 = spawn_state["character_position"]
	var yaw: float = spawn_state["yaw"]
	_spawn_character(peer_id, _is_local_peer(peer_id), character_position, yaw)


func _sync_spawn_states_to_peer(target_peer_id: int) -> void:
	for peer_id in _sorted_peer_ids():
		var spawn_state: Dictionary = _peer_spawn_states[peer_id]
		record_net_send("spawn", [peer_id, spawn_state["character_position"], spawn_state["yaw"]])
		spawn_character.rpc_id(
			target_peer_id,
			peer_id,
			spawn_state["character_position"],
			spawn_state["yaw"]
		)
	_health_net.sync_health_states_to_peer(target_peer_id)


func _broadcast_spawn_state(peer_id: int, excluded_peer_id: int) -> void:
	var spawn_state: Dictionary = _peer_spawn_states[peer_id]
	for target_peer_id in multiplayer.get_peers():
		if target_peer_id == excluded_peer_id or not _is_peer_world_ready(target_peer_id):
			continue

		record_net_send("spawn", [peer_id, spawn_state["character_position"], spawn_state["yaw"]])
		spawn_character.rpc_id(
			target_peer_id,
			peer_id,
			spawn_state["character_position"],
			spawn_state["yaw"]
		)


func _sorted_peer_ids() -> Array:
	var peer_ids := _peer_spawn_states.keys()
	peer_ids.sort()
	return peer_ids


func _get_lobby_peer_ids() -> Array:
	var peer_ids: Array = []
	var lobby := get_node_or_null("/root/Lobby")
	if lobby == null:
		return peer_ids

	var lobby_players: Variant = lobby.get("players")
	if not lobby_players is Dictionary:
		return peer_ids

	var players: Dictionary = lobby_players
	for peer_id in players.keys():
		if peer_id is int:
			peer_ids.append(peer_id)

	return peer_ids


func _build_radial_spawn_state(index: int, player_count: int) -> Dictionary:
	var angle := TAU * float(index) / float(player_count)
	var radius: float = spawn_radius
	if radius < 0.0:
		radius = 0.0
	var spawn_origin := _get_spawn_origin()
	var character_position := spawn_origin + Vector3(sin(angle) * radius, 0.0, cos(angle) * radius)

	return {
		"character_position": character_position,
		"yaw": _yaw_towards(character_position, spawn_origin)
	}


func _build_late_join_spawn_state() -> Dictionary:
	var min_radius: float = max(late_join_spawn_min_radius, 0.0)
	var max_radius: float = max(late_join_spawn_max_radius, min_radius)
	var angle: float = _spawn_random.randf_range(0.0, TAU)
	var radius: float = _spawn_random.randf_range(min_radius, max_radius)
	var spawn_origin := _get_spawn_origin()
	var character_position := spawn_origin + Vector3(sin(angle) * radius, 0.0, cos(angle) * radius)

	return {
		"character_position": character_position,
		"yaw": _yaw_towards(character_position, spawn_origin)
	}


func _build_bot_spawn_state(index: int, total_bots: int) -> Dictionary:
	var count: int = max(total_bots, 1)
	var radius := maxf(bot_spawn_radius, 0.0)
	var angle := TAU * float(index) / float(count)
	var spawn_origin := _get_spawn_origin()
	var bot_position := spawn_origin + Vector3(sin(angle) * radius, 0.0, cos(angle) * radius)

	var target_position := spawn_origin
	if _bot_follow_target != null:
		target_position = _bot_follow_target.global_position

	return {
		"character_position": bot_position,
		"yaw": _yaw_towards(bot_position, target_position)
	}


func _get_spawn_origin() -> Vector3:
	return spawn_center + Vector3(0.0, spawn_height_offset, 0.0)


func _is_local_peer(peer_id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return false

	return peer_id == multiplayer.get_unique_id()


func get_character(peer_id: int) -> Node3D:
	return _characters.get_node_or_null(_character_name(peer_id)) as Node3D


func get_projectile_net():
	return _projectile_net


func get_target_registry():
	return _target_registry


func _set_character_local_binding(character: Node3D, local_player: bool) -> void:
	var is_mp := multiplayer.multiplayer_peer != null
	var is_server := is_mp and multiplayer.is_server()

	# Input binding: a pure client forwards its own plane's input intent to the
	# server instead of submitting poses.
	var plane_character := character as PlaneCharacter
	if plane_character == null:
		return

	var input_callback := Callable(self, "_on_local_character_input_produced")
	var input_connected: bool = plane_character.local_input_produced.is_connected(input_callback)
	var should_bind_input := is_mp and not is_server and local_player

	if should_bind_input and not input_connected:
		plane_character.local_input_produced.connect(input_callback)
	elif not should_bind_input and input_connected:
		plane_character.local_input_produced.disconnect(input_callback)


func _enforce_local_ownership() -> void:
	if multiplayer.multiplayer_peer == null:
		return

	var local_peer_id := multiplayer.get_unique_id()
	for character in _characters.get_children():
		var character_peer_id: int = character.peer_id
		var local_player: bool = character_peer_id == local_peer_id
		character.configure(character_peer_id, local_player)
		_set_character_local_binding(character, local_player)
		if character_type == CharacterType.PLANE:
			character.set_server_net_tick_hz(server_net_tick_hz)
			_configure_bot_behavior(character, character_peer_id)

		if local_player and character_type == CharacterType.PLANE:
			_bind_local_plane_presentation(character)

	_update_local_plane_presentation_binding()


func _is_peer_world_ready(peer_id: int) -> bool:
	if peer_id == multiplayer.get_unique_id():
		return true

	return bool(_world_ready_peers.get(peer_id, false))


func is_peer_world_ready(peer_id: int) -> bool:
	return _is_peer_world_ready(peer_id)


func _register_lockable_target(character: Node3D) -> void:
	if _target_registry == null or character == null:
		return
	var lockable_target = character.get_node_or_null("LockableTarget")
	if lockable_target != null:
		_target_registry.register_target(lockable_target)


func _unregister_lockable_target(character: Node3D) -> void:
	if _target_registry == null or character == null:
		return
	var lockable_target = character.get_node_or_null("LockableTarget")
	if lockable_target != null:
		_target_registry.unregister_target(lockable_target)


func _broadcast_world_snapshot() -> void:
	var world_snapshot := _build_world_snapshot()
	var planes: Array = world_snapshot.get("planes", [])
	if planes.is_empty():
		return
	var encoded_snapshot := NET_WIRE.encode_world_snapshot(int(world_snapshot.get("tick", -1)), planes)

	for target_peer_id in multiplayer.get_peers():
		if not _is_peer_world_ready(target_peer_id):
			continue

		record_net_send("state", encoded_snapshot)
		apply_world_snapshot.rpc_id(target_peer_id, encoded_snapshot)


func _build_world_snapshot() -> Dictionary:
	_world_snapshot_tick += 1
	var planes: Array[Dictionary] = []
	for peer_id in _sorted_peer_ids():
		var plane_character := get_character(peer_id) as PlaneCharacter
		if plane_character == null or not is_instance_valid(plane_character):
			continue
		var snapshot := plane_character.build_state_for_batch(_world_snapshot_tick)
		snapshot["peer_id"] = peer_id
		planes.append(snapshot)
	return {
		"tick": _world_snapshot_tick,
		"planes": planes,
	}


func _broadcast_despawn(peer_id: int) -> void:
	for target_peer_id in multiplayer.get_peers():
		if not _is_peer_world_ready(target_peer_id):
			continue

		record_net_send("spawn", [peer_id])
		despawn_character.rpc_id(target_peer_id, peer_id)


func _yaw_towards(character_position: Vector3, target_position: Vector3) -> float:
	var direction := target_position - character_position
	direction.y = 0.0
	if direction.length_squared() <= 0.0001:
		return 0.0

	direction = direction.normalized()
	return atan2(-direction.x, -direction.z)


func _get_character_scene() -> PackedScene:
	match character_type:
		CharacterType.PLANE:
			return PLANE_CHARACTER_SCENE
		_:
			return PLAYER_CHARACTER_SCENE


func _update_local_plane_presentation_binding() -> void:
	var local_character := _find_local_character()
	if character_type != CharacterType.PLANE or local_character == null:
		_clear_local_plane_presentation_target()
		return

	_bind_local_plane_presentation(local_character)


func _find_local_character() -> Node3D:
	var local_peer_id := 1
	if multiplayer.multiplayer_peer != null:
		local_peer_id = multiplayer.get_unique_id()

	for character in _characters.get_children():
		if character.peer_id == local_peer_id:
			return character

	return null


func _bind_local_plane_presentation(character: Node3D) -> void:
	if character_type != CharacterType.PLANE:
		return

	if _local_plane_presentation != null:
		_local_plane_presentation.bind(character)


func _clear_local_plane_presentation_target() -> void:
	if _local_plane_presentation != null:
		_local_plane_presentation.clear()


func _on_display_settings_changed() -> void:
	for character in _characters.get_children():
		_apply_display_settings_to_character(character)


func _apply_display_settings_to_character(character: Node) -> void:
	DISPLAY_SETTINGS_APPLIER.apply_to_character(character)


func _apply_client_aero_tables_to_character(character: Node) -> void:
	if _client_aero_payload.is_empty():
		return

	var plane_character := character as PlaneCharacter
	if plane_character != null:
		plane_character.apply_aero_tables_payload(_client_aero_payload)


func _has_property(object: Object, property_name: String) -> bool:
	return DISPLAY_SETTINGS_APPLIER._has_property(object, property_name)


func record_net_send(kind: String, payload: Variant) -> void:
	record_net_send_bytes(kind, _estimate_payload_bytes(payload))


func record_net_recv(kind: String, payload: Variant) -> void:
	record_net_recv_bytes(kind, _estimate_payload_bytes(payload))


func record_net_send_bytes(kind: String, byte_len: int) -> void:
	if not net_metrics_enabled:
		return
	_net_metrics.record_send(kind, byte_len)


func record_net_recv_bytes(kind: String, byte_len: int) -> void:
	if not net_metrics_enabled:
		return
	_net_metrics.record_recv(kind, byte_len)


func get_net_metrics_summary() -> Dictionary:
	if not net_metrics_enabled:
		return {}
	return _net_metrics.get_summary()


func get_net_metrics_summary_text() -> String:
	if not net_metrics_enabled:
		return ""
	return _net_metrics.get_summary_text()


func _estimate_payload_bytes(payload: Variant) -> int:
	if payload is PackedByteArray:
		return (payload as PackedByteArray).size()
	return var_to_bytes(payload).size()


func _check_packet_budget() -> void:
	if not net_metrics_enabled:
		return
	if packet_budget_pkts_per_sec <= 0.0:
		_packet_budget_warning_active = false
		return

	var summary := get_net_metrics_summary()
	var send_summary: Dictionary = summary.get("send", {})
	var total_packets_per_sec := float(send_summary.get("packets_per_sec", 0.0))
	var peer_count := maxf(float(_get_budget_target_peer_count()), 1.0)
	var per_peer_packets_per_sec := total_packets_per_sec / peer_count
	if per_peer_packets_per_sec > packet_budget_pkts_per_sec:
		if not _packet_budget_warning_active:
			_packet_budget_warning_active = true
			push_warning(
				"Net packet budget exceeded: %.1f pkt/s per peer > %.1f budget" % [
					per_peer_packets_per_sec,
					packet_budget_pkts_per_sec,
				]
			)
	elif _packet_budget_warning_active:
		_packet_budget_warning_active = false


func _get_budget_target_peer_count() -> int:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return 1

	var ready_peer_count := 0
	for target_peer_id in multiplayer.get_peers():
		if _is_peer_world_ready(target_peer_id):
			ready_peer_count += 1
	return maxi(ready_peer_count, 1)
