class_name WorldCharacterSpawner
extends Node3D

const PLANE_CHARACTER_SCENE := preload("res://scenes/plane_character.tscn")
const DISPLAY_SETTINGS_APPLIER := preload("res://scripts/display_settings_applier.gd")
const LOCAL_PLANE_PRESENTATION_BINDING := preload("res://scripts/local_plane_presentation_binding.gd")
const NET_METRICS_SCRIPT := preload("res://scripts/net_metrics.gd")
const NET_WIRE := preload("res://scripts/net_wire.gd")
const PLANE_BOT_SETUP := preload("res://scripts/plane_bot_setup.gd")
const SINGLE_PLAYER_MATCH_HUD_SCENE := preload("res://scenes/single_player_match_hud.tscn")
const CHARACTER_NAME_PREFIX := "PlayerCharacter_"
const BOT_PEER_ID_BASE := 1000000
const SINGLE_PLAYER_END_STATE_DELAY_SEC := 8.0
const SINGLE_PLAYER_GAME_OVER_TITLE := "Game Over"
const SINGLE_PLAYER_VICTORY_TITLE := "Victory"

@export var spawn_center := Vector3.ZERO
@export var spawn_height_offset: float = 1500.0
@export var spawn_radius := 480.0
@export var late_join_spawn_min_radius := 300.0
@export var late_join_spawn_max_radius := 600.0
@export var spawn_forward_speed: float = 100.0
@export var bot_count := 1
@export var bot_team_ids: PackedInt32Array = []
@export var bot_spawn_radius := 2400.0
@export var bot_parallel_separation: float = 1000.0
@export var bot_player_killzone_distance := 250.0
@export var bot_player_killzone_tolerance := 150.0
@export var single_player_victory_score: int = 5
@export var single_player_time_limit_sec: float = 180.0
@export var server_net_tick_hz: float = 30.0
@export var packet_budget_pkts_per_sec: float = 35.0
@export var net_metrics_enabled := false
@export var net_metrics_print_summary := false
@onready var _systems_root: Node = get_parent()
@onready var _characters: Node3D = _systems_root.get_node("characters") as Node3D
@onready var _projectiles: Node3D = _systems_root.get_node("projectiles") as Node3D
@onready var _target_registry = _systems_root.get_node("TargetRegistry")
@onready var _projectile_net = _systems_root.get_node("ProjectileNetReplicator")
@onready var _health_net = _systems_root.get_node("HealthNetReplicator")
@onready var _game_menu: CanvasLayer = _systems_root.get_node("ui") as CanvasLayer

var _peer_spawn_states: Dictionary = {}
var _bot_peer_ids: Dictionary = {}
var _world_ready_peers: Dictionary = {}
var _spawn_random := RandomNumberGenerator.new()
var _local_plane_presentation
var _server_aero_payload: Dictionary = {}
var _client_aero_payload: Dictionary = {}
var _net_metrics := NET_METRICS_SCRIPT.new()
var _net_metrics_print_accumulator := 0.0
var _world_snapshot_tick := 0
var _world_snapshot_accumulator := 0.0
var _packet_budget_warning_active := false
var _single_player_match_hud
var _single_player_end_state_timer: Timer = null
var _pending_single_player_end_state_title := ""
var _single_player_rules_active := false
var _single_player_score := 0
var _single_player_time_remaining_sec := 0.0
var _single_player_tracked_hostiles: Dictionary = {}
var _bot_team_overrides: Dictionary = {}
var _session_started := false


func _ready() -> void:
	add_to_group("world_character_spawner")
	_spawn_random.randomize()
	_local_plane_presentation = LOCAL_PLANE_PRESENTATION_BINDING.new(self)
	_projectile_net.configure(self, _projectiles)
	_health_net.configure(self)
	_apply_lobby_bot_count_override()
	DisplaySettings.settings_changed.connect(_on_display_settings_changed)

	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_world_ready_peers[multiplayer.get_unique_id()] = true
	elif multiplayer.multiplayer_peer != null:
		call_deferred("_request_world_sync")


func begin_default_session() -> void:
	if _session_started:
		return
	if multiplayer.multiplayer_peer == null:
		begin_single_player_session_from_state(_build_radial_spawn_state(0, 1))
		return
	if multiplayer.is_server():
		begin_server_session_from_player_specs([])


func begin_single_player_session_from_state(spawn_state: Dictionary) -> void:
	if _session_started:
		return
	_session_started = true
	if bot_count < 1:
		bot_count = 1

	_peer_spawn_states[1] = spawn_state
	_spawn_character(
		1,
		true,
		spawn_state["character_position"],
		spawn_state["yaw"],
		spawn_state["forward_speed"]
	)
	_spawn_single_player_bots(spawn_state)
	_ensure_single_player_match_hud()
	_setup_single_player_end_state_tracking()


func begin_server_session_from_player_specs(player_specs: Array[Dictionary]) -> void:
	if _session_started:
		return
	_session_started = true
	_register_initial_peers(player_specs)
	_spawn_registered_characters_locally()
	_spawn_bots(true)


func _process(delta: float) -> void:
	_update_single_player_timer(delta)
	_tick_world_snapshot_broadcast(delta)

	if not net_metrics_enabled or not net_metrics_print_summary:
		return

	_net_metrics_print_accumulator += delta
	if _net_metrics_print_accumulator < 1.0:
		return

	_net_metrics_print_accumulator = 0.0
	_check_packet_budget()
	print("net_metrics %s" % get_net_metrics_summary_text())


func _update_single_player_timer(delta: float) -> void:
	if not _single_player_rules_active:
		return
	if not _pending_single_player_end_state_title.is_empty():
		return
	if single_player_time_limit_sec <= 0.0:
		return

	_single_player_time_remaining_sec = maxf(_single_player_time_remaining_sec - delta, 0.0)
	if _single_player_time_remaining_sec <= 0.0:
		_schedule_single_player_end_state(SINGLE_PLAYER_GAME_OVER_TITLE)


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


func _register_initial_peers(player_specs: Array[Dictionary] = []) -> void:
	var peer_ids := _get_lobby_peer_ids()
	var server_peer_id := multiplayer.get_unique_id()
	if not peer_ids.has(server_peer_id):
		peer_ids.append(server_peer_id)

	peer_ids.sort()
	var player_count := peer_ids.size()
	for index in range(player_count):
		var peer_id: int = peer_ids[index]
		if not _peer_spawn_states.has(peer_id):
			if index < player_specs.size():
				var spawn_spec: Dictionary = player_specs[index]
				_peer_spawn_states[peer_id] = _make_spawn_state(
					spawn_spec["position"],
					float(spawn_spec.get("yaw", 0.0)),
					float(spawn_spec.get("speed", _get_spawn_forward_speed()))
				)
			else:
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
		_spawn_character_from_state(bot_peer_id, false, bot_spawn_state)

		if broadcast_to_clients and multiplayer.multiplayer_peer != null and multiplayer.is_server():
			_broadcast_spawn_state(bot_peer_id, -1)


func _spawn_single_player_bots(player_spawn_state: Dictionary) -> void:
	if bot_count <= 0:
		return

	var player_pos: Vector3 = player_spawn_state["character_position"]
	var player_yaw: float = player_spawn_state["yaw"]
	var player_forward_speed: float = float(player_spawn_state.get("forward_speed", _get_spawn_forward_speed()))
	var player_right := Vector3(cos(player_yaw), 0.0, -sin(player_yaw))

	var resolved_bot_count: int = maxi(bot_count, 0)
	for bot_index in range(resolved_bot_count):
		var bot_peer_id := BOT_PEER_ID_BASE + bot_index
		if _peer_spawn_states.has(bot_peer_id):
			continue

		var bot_position := player_pos + player_right * bot_parallel_separation * float(bot_index + 1)
		var bot_spawn_state := _make_spawn_state(bot_position, player_yaw, player_forward_speed)
		_peer_spawn_states[bot_peer_id] = bot_spawn_state
		_bot_peer_ids[bot_peer_id] = true
		_spawn_character_from_state(bot_peer_id, false, bot_spawn_state)


func _configure_bot_behavior(character: Node3D, peer_id: int) -> void:
	if character == null:
		return

	var bot_peer := _is_bot_peer(peer_id)
	var bot_active := bot_peer and (multiplayer.multiplayer_peer == null or multiplayer.is_server())

	PLANE_BOT_SETUP.configure_plane(
		character,
		bot_peer,
		bot_active,
		bot_player_killzone_distance,
		bot_player_killzone_tolerance
	)

	if bot_peer and character.has_method("apply_default_aero_tables"):
		character.call("apply_default_aero_tables")
	if bot_peer and _bot_team_overrides.has(peer_id):
		character.team_id = int(_bot_team_overrides[peer_id])
		return
	var bot_index := peer_id - BOT_PEER_ID_BASE
	if bot_peer and bot_index >= 0 and bot_index < bot_team_ids.size():
		character.team_id = bot_team_ids[bot_index]


func _is_bot_peer(peer_id: int) -> bool:
	return _bot_peer_ids.has(peer_id)


func _spawn_character(
	peer_id: int,
	local_player: bool,
	character_position: Vector3,
	yaw: float,
	forward_speed: float = 0.0
) -> Node3D:
	var existing := _characters.get_node_or_null(_character_name(peer_id)) as Node3D
	if existing != null:
		_configure_character_identity(existing, peer_id, local_player)
		_configure_spawned_character(existing, peer_id, local_player)
		return existing

	var character := PLANE_CHARACTER_SCENE.instantiate() as Node3D
	character.name = _character_name(peer_id)
	character.position = character_position
	character.rotation.y = yaw
	_configure_character_identity(character, peer_id, local_player)
	_characters.add_child(character, true)
	var spawn_velocity := Vector3.ZERO
	if character is RigidBody3D:
		spawn_velocity = -(character as RigidBody3D).basis.z * maxf(forward_speed, 0.0)

	_configure_spawned_character(character, peer_id, local_player)

	if character is RigidBody3D:
		var body := character as RigidBody3D
		body.linear_velocity = spawn_velocity
		body.sleeping = false
	return character


func _configure_character_identity(character: Node3D, peer_id: int, local_player: bool) -> void:
	character.configure(peer_id, local_player)


func _configure_spawned_character(character: Node3D, peer_id: int, local_player: bool) -> void:
	_set_character_local_binding(character, local_player)
	var plane := character as PlaneCharacter
	if plane == null:
		return

	plane.set_server_net_tick_hz(server_net_tick_hz)
	_configure_bot_behavior(plane, peer_id)
	_register_lockable_target(plane)
	_health_net.bind_character(plane, peer_id)
	_apply_display_settings_to_character(plane)
	_apply_client_aero_tables_to_character(plane)
	if local_player:
		_bind_local_plane_presentation(plane)


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
	_bot_team_overrides.erase(peer_id)

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
func spawn_character(peer_id: int, character_position: Vector3, yaw: float, forward_speed: float) -> void:
	record_net_recv("spawn", [peer_id, character_position, yaw, forward_speed])
	_spawn_character(peer_id, _is_local_peer(peer_id), character_position, yaw, forward_speed)
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
	_spawn_character_from_state(peer_id, _is_local_peer(peer_id), spawn_state)


func _sync_spawn_states_to_peer(target_peer_id: int) -> void:
	for peer_id in _sorted_peer_ids():
		var spawn_state: Dictionary = _peer_spawn_states[peer_id]
		_send_spawn_state_to_peer(target_peer_id, peer_id, spawn_state)
	_health_net.sync_health_states_to_peer(target_peer_id)


func _broadcast_spawn_state(peer_id: int, excluded_peer_id: int) -> void:
	var spawn_state: Dictionary = _peer_spawn_states[peer_id]
	for target_peer_id in multiplayer.get_peers():
		if target_peer_id == excluded_peer_id or not _is_peer_world_ready(target_peer_id):
			continue

		_send_spawn_state_to_peer(target_peer_id, peer_id, spawn_state)


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
	return _make_spawn_state(character_position, _yaw_towards(character_position, spawn_origin))


func _build_late_join_spawn_state() -> Dictionary:
	var min_radius: float = max(late_join_spawn_min_radius, 0.0)
	var max_radius: float = max(late_join_spawn_max_radius, min_radius)
	var angle: float = _spawn_random.randf_range(0.0, TAU)
	var radius: float = _spawn_random.randf_range(min_radius, max_radius)
	var spawn_origin := _get_spawn_origin()
	var character_position := spawn_origin + Vector3(sin(angle) * radius, 0.0, cos(angle) * radius)
	return _make_spawn_state(character_position, _yaw_towards(character_position, spawn_origin))


func _build_bot_spawn_state(index: int, total_bots: int) -> Dictionary:
	var count: int = max(total_bots, 1)
	var radius := maxf(bot_spawn_radius, 0.0)
	var angle := TAU * float(index) / float(count)
	var spawn_origin := _get_spawn_origin()
	var bot_position := spawn_origin + Vector3(sin(angle) * radius, 0.0, cos(angle) * radius)
	return _make_spawn_state(bot_position, _yaw_towards(bot_position, spawn_origin))


func _get_spawn_origin() -> Vector3:
	return spawn_center + Vector3(0.0, spawn_height_offset, 0.0)


func _make_spawn_state(character_position: Vector3, yaw: float, forward_speed: float = -1.0) -> Dictionary:
	return {
		"character_position": character_position,
		"yaw": yaw,
		"forward_speed": _get_spawn_forward_speed() if forward_speed < 0.0 else maxf(forward_speed, 0.0),
	}


func _get_spawn_forward_speed() -> float:
	return maxf(spawn_forward_speed, 0.0)


func _get_spawn_state_forward_speed(spawn_state: Dictionary) -> float:
	return float(spawn_state.get("forward_speed", _get_spawn_forward_speed()))


func _spawn_character_from_state(peer_id: int, local_player: bool, spawn_state: Dictionary) -> Node3D:
	var character_position: Vector3 = spawn_state["character_position"]
	var yaw: float = spawn_state["yaw"]
	return _spawn_character(peer_id, local_player, character_position, yaw, _get_spawn_state_forward_speed(spawn_state))


func spawn_player_character(
	peer_id: int,
	character_position: Vector3,
	yaw: float,
	forward_speed: float = 100.0
) -> Node3D:
	_bot_peer_ids.erase(peer_id)
	_bot_team_overrides.erase(peer_id)
	var spawn_state := _make_spawn_state(character_position, yaw, forward_speed)
	_peer_spawn_states[peer_id] = spawn_state
	var character := _spawn_character_from_state(peer_id, _is_local_peer(peer_id), spawn_state)
	_enforce_local_ownership()
	return character


func spawn_bot_character(
	character_position: Vector3,
	yaw: float,
	team_id: int,
	forward_speed: float = 100.0
) -> Node3D:
	var peer_id := _allocate_bot_peer_id()
	_bot_peer_ids[peer_id] = true
	_bot_team_overrides[peer_id] = team_id
	var spawn_state := _make_spawn_state(character_position, yaw, forward_speed)
	_peer_spawn_states[peer_id] = spawn_state
	return _spawn_character_from_state(peer_id, false, spawn_state)


func _allocate_bot_peer_id() -> int:
	var peer_id := BOT_PEER_ID_BASE
	while _peer_spawn_states.has(peer_id) or _bot_peer_ids.has(peer_id):
		peer_id += 1
	return peer_id


func _send_spawn_state_to_peer(target_peer_id: int, peer_id: int, spawn_state: Dictionary) -> void:
	var character_position: Vector3 = spawn_state["character_position"]
	var yaw: float = spawn_state["yaw"]
	var forward_speed := _get_spawn_state_forward_speed(spawn_state)
	record_net_send("spawn", [peer_id, character_position, yaw, forward_speed])
	spawn_character.rpc_id(target_peer_id, peer_id, character_position, yaw, forward_speed)


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
		var plane := character as PlaneCharacter
		if plane != null:
			plane.set_server_net_tick_hz(server_net_tick_hz)
			_configure_bot_behavior(plane, character_peer_id)

		if local_player and plane != null:
			_bind_local_plane_presentation(plane)

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


func _update_local_plane_presentation_binding() -> void:
	var local_character := _find_local_character()
	if local_character == null:
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


func _ensure_single_player_match_hud() -> void:
	if _single_player_match_hud == null:
		_single_player_match_hud = SINGLE_PLAYER_MATCH_HUD_SCENE.instantiate()
		_systems_root.add_child(_single_player_match_hud)

	if _single_player_match_hud.has_method("set_world_spawner"):
		_single_player_match_hud.call("set_world_spawner", self)


func _setup_single_player_end_state_tracking() -> void:
	var local_character := _find_local_character()
	if local_character == null:
		return

	_single_player_rules_active = true
	_single_player_score = 0
	_single_player_time_remaining_sec = maxf(single_player_time_limit_sec, 0.0)
	_single_player_tracked_hostiles.clear()

	var local_health := _get_health_component_for_node(local_character)
	if local_health != null:
		var player_shot_down_callback := Callable(self, "_on_single_player_local_shot_down")
		if not local_health.shot_down.is_connected(player_shot_down_callback):
			local_health.shot_down.connect(player_shot_down_callback)

	for enemy in _collect_single_player_hostile_targets(local_character):
		_single_player_tracked_hostiles[enemy.get_instance_id()] = enemy
		var enemy_health := _get_health_component_for_node(enemy)
		if enemy_health == null:
			continue
		var enemy_shot_down_callback := Callable(self, "_on_single_player_enemy_shot_down").bind(enemy)
		if not enemy_health.shot_down.is_connected(enemy_shot_down_callback):
			enemy_health.shot_down.connect(enemy_shot_down_callback)


func _collect_single_player_hostile_targets(local_character: Node3D) -> Array[Node3D]:
	var hostiles: Array[Node3D] = []
	_append_single_player_hostile_targets(self, local_character, hostiles)
	return hostiles


func _append_single_player_hostile_targets(node: Node, local_character: Node3D, hostiles: Array[Node3D]) -> void:
	var candidate := node as Node3D
	if candidate != null and candidate != local_character and _is_single_player_hostile_target(candidate, local_character):
		hostiles.append(candidate)

	for child in node.get_children():
		_append_single_player_hostile_targets(child, local_character, hostiles)


func _is_single_player_hostile_target(candidate: Node3D, local_character: Node3D) -> bool:
	if not ("team_id" in candidate) or not ("is_shot_down" in candidate):
		return false
	if bool(candidate.get("is_shot_down")):
		return false

	var health := _get_health_component_for_node(candidate)
	if health == null:
		return false

	var local_team_id := int(local_character.get("team_id"))
	var candidate_team_id := int(candidate.get("team_id"))
	if local_team_id > 0 and candidate_team_id > 0 and candidate_team_id == local_team_id:
		return false

	return true


func _get_health_component_for_node(node: Node) -> Health:
	if node == null:
		return null
	if node.has_method("get_health_component"):
		return node.call("get_health_component") as Health
	return node.get_node_or_null("Health") as Health


func _on_single_player_local_shot_down() -> void:
	_schedule_single_player_end_state(SINGLE_PLAYER_GAME_OVER_TITLE)


func _on_single_player_enemy_shot_down(enemy: Node3D) -> void:
	var enemy_id := enemy.get_instance_id()
	if not _single_player_tracked_hostiles.has(enemy_id):
		return

	_single_player_tracked_hostiles.erase(enemy_id)
	_single_player_score += 1

	if _has_single_player_score_victory():
		_schedule_single_player_end_state(SINGLE_PLAYER_VICTORY_TITLE)
		return
	if _count_single_player_alive_hostiles() > 0:
		return
	_schedule_single_player_end_state(SINGLE_PLAYER_VICTORY_TITLE)


func _count_single_player_alive_hostiles() -> int:
	return _single_player_tracked_hostiles.size()


func _has_single_player_score_victory() -> bool:
	return single_player_victory_score > 0 and _single_player_score >= single_player_victory_score


func _schedule_single_player_end_state(title: String) -> void:
	if not _pending_single_player_end_state_title.is_empty():
		return

	_pending_single_player_end_state_title = title
	if _single_player_end_state_timer == null:
		_single_player_end_state_timer = Timer.new()
		_single_player_end_state_timer.one_shot = true
		_single_player_end_state_timer.process_mode = Node.PROCESS_MODE_ALWAYS
		_single_player_end_state_timer.timeout.connect(_on_single_player_end_state_timeout)
		add_child(_single_player_end_state_timer)

	_single_player_end_state_timer.wait_time = SINGLE_PLAYER_END_STATE_DELAY_SEC
	_single_player_end_state_timer.start()


func _on_single_player_end_state_timeout() -> void:
	if _pending_single_player_end_state_title.is_empty():
		return
	if _game_menu != null and _game_menu.has_method("show_end_state"):
		_game_menu.call("show_end_state", _pending_single_player_end_state_title)


func is_single_player_session() -> bool:
	return _single_player_rules_active


func get_single_player_score() -> int:
	return _single_player_score


func get_single_player_victory_score() -> int:
	return max(single_player_victory_score, 0)


func has_single_player_time_limit() -> bool:
	return _single_player_rules_active and single_player_time_limit_sec > 0.0


func get_single_player_time_remaining_sec() -> float:
	return maxf(_single_player_time_remaining_sec, 0.0)


func _bind_local_plane_presentation(character: Node3D) -> void:
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
