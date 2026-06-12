class_name WorldCharacterSpawner
extends Node3D

const PLAYER_CHARACTER_SCENE := preload("res://scenes/player_character.tscn")
const PLANE_CHARACTER_SCENE := preload("res://scenes/plane_character.tscn")
const DISPLAY_SETTINGS_APPLIER := preload("res://scripts/display_settings_applier.gd")
const MISSILE_SCENE := preload("res://scenes/missile.tscn")
const BULLET_SCENE := preload("res://scenes/bullet.tscn")
const BULLET_VISUAL_SCENE := preload("res://scenes/bullet_visual.tscn")
const EXPLOSION_SCENE := preload("res://scenes/explosion.tscn")
const AUTOCANNON_SCRIPT := preload("res://scripts/autocannon.gd")
const LOCAL_PLANE_PRESENTATION_BINDING := preload("res://scripts/local_plane_presentation_binding.gd")
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
@export var bot_spawn_radius := 2400.0
@export var bot_follow_target_path: NodePath = NodePath("level/BotFollowTarget")
@export var bot_player_killzone_distance := 250.0
@export var bot_player_killzone_tolerance := 150.0
@onready var _characters: Node3D = $characters
@onready var _projectiles: Node3D = $projectiles

var _peer_spawn_states: Dictionary = {}
var _next_missile_id: int = 0
var _active_missiles: Dictionary = {}
var _remote_missiles: Dictionary = {}
var _next_bullet_id: int = 0
var _active_bullets: Dictionary = {}
var _active_bullet_visuals: Dictionary = {}
var _gun_cooldowns: Dictionary = {}
var _missile_cooldowns: Dictionary = {}
var _bot_peer_ids: Dictionary = {}
var _world_ready_peers: Dictionary = {}
var _spawn_random := RandomNumberGenerator.new()
var _bot_follow_target: Node3D
var _local_plane_presentation
var _server_aero_payload: Dictionary = {}
var _client_aero_payload: Dictionary = {}


func _ready() -> void:
	add_to_group("world_character_spawner")
	_spawn_random.randomize()
	_local_plane_presentation = LOCAL_PLANE_PRESENTATION_BINDING.new(self)
	_resolve_bot_follow_target()
	_apply_lobby_bot_count_override()
	DisplaySettings.settings_changed.connect(_on_display_settings_changed)
	if multiplayer.multiplayer_peer != null:
		_projectiles.child_entered_tree.connect(_on_projectile_entered)

	if multiplayer.multiplayer_peer == null:
		if bot_count < 1:
			bot_count = 1

		var participant_count: int = 1 + maxi(bot_count, 0)
		var spawn_state := _build_radial_spawn_state(0, participant_count)
		_spawn_character(1, true, spawn_state["character_position"], spawn_state["yaw"])
		_spawn_single_player_bots(participant_count)
		return

	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_world_ready_peers[multiplayer.get_unique_id()] = true
		_register_initial_peers()
		_spawn_registered_characters_locally()
		_spawn_bots(true)
	else:
		call_deferred("_request_world_sync")


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


func _spawn_single_player_bots(total_participants: int) -> void:
	if bot_count <= 0:
		return

	var resolved_bot_count: int = maxi(bot_count, 0)
	var radial_count: int = maxi(total_participants, 1)
	for bot_index in range(resolved_bot_count):
		var bot_peer_id := BOT_PEER_ID_BASE + bot_index
		if _peer_spawn_states.has(bot_peer_id):
			continue

		var bot_spawn_state := _build_radial_spawn_state(bot_index + 1, radial_count)
		_peer_spawn_states[bot_peer_id] = bot_spawn_state
		_bot_peer_ids[bot_peer_id] = true
		_spawn_character(
			bot_peer_id,
			false,
			bot_spawn_state["character_position"],
			bot_spawn_state["yaw"]
		)


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


func _is_bot_peer(peer_id: int) -> bool:
	return _bot_peer_ids.has(peer_id)


func _spawn_character(peer_id: int, local_player: bool, character_position: Vector3, yaw: float) -> Node3D:
	var existing := _characters.get_node_or_null(_character_name(peer_id)) as Node3D
	if existing != null:
		if character_type == CharacterType.PLANE:
			var existing_plane := existing
			existing_plane.configure(peer_id, local_player)
			_set_character_local_binding(existing_plane, local_player)
			_configure_bot_behavior(existing_plane, peer_id)
			_bind_character_health_replication(existing_plane, peer_id)
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
		_set_character_local_binding(plane, local_player)
		_configure_bot_behavior(plane, peer_id)
		_bind_character_health_replication(plane, peer_id)
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


func _on_local_character_state_changed(peer_id: int, snapshot: Dictionary) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	_broadcast_character_state(peer_id, snapshot)


func _on_local_character_input_produced(_peer_id: int, input: Dictionary) -> void:
	if multiplayer.multiplayer_peer == null or multiplayer.is_server():
		return

	sv_submit_input.rpc_id(1, input)


func _request_world_sync() -> void:
	if multiplayer.multiplayer_peer == null or multiplayer.is_server():
		return

	request_world_sync.rpc_id(1)


@rpc("any_peer", "reliable")
func request_world_sync() -> void:
	if not multiplayer.is_server():
		return

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

	_client_aero_payload = payload.duplicate(true)
	for character in _characters.get_children():
		var plane_character := character as PlaneCharacter
		if plane_character != null:
			plane_character.apply_aero_tables_payload(_client_aero_payload)


@rpc("authority", "reliable")
func spawn_character(peer_id: int, character_position: Vector3, yaw: float) -> void:
	_spawn_character(peer_id, _is_local_peer(peer_id), character_position, yaw)
	_enforce_local_ownership()


@rpc("authority", "reliable")
func despawn_character(peer_id: int) -> void:
	_despawn_character(peer_id)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func sv_submit_input(input: Dictionary) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var plane_character := _characters.get_node_or_null(_character_name(sender_id)) as PlaneCharacter
	if plane_character == null or not is_instance_valid(plane_character):
		return
	if plane_character.is_shot_down:
		return
	if not _is_valid_input_packet(input):
		return
	plane_character.apply_net_control_input(input)


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
		"limiter_override_active",
	]:
		if input.has(bool_key) and not (input.get(bool_key) is bool):
			return false
	return true


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func apply_character_state(peer_id: int, snapshot: Dictionary) -> void:
	var character := _characters.get_node_or_null(_character_name(peer_id))
	if character == null:
		return

	if peer_id == multiplayer.get_unique_id():
		# Server echo of our own plane: reconciliation (or wreck interpolation).
		var plane_character := character as PlaneCharacter
		if plane_character != null:
			plane_character.apply_authoritative_state(snapshot)
		return

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
		spawn_character.rpc_id(
			target_peer_id,
			peer_id,
			spawn_state["character_position"],
			spawn_state["yaw"]
		)
	_sync_health_states_to_peer(target_peer_id)


func _broadcast_spawn_state(peer_id: int, excluded_peer_id: int) -> void:
	var spawn_state: Dictionary = _peer_spawn_states[peer_id]
	for target_peer_id in multiplayer.get_peers():
		if target_peer_id == excluded_peer_id or not _is_peer_world_ready(target_peer_id):
			continue

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


func _set_character_local_binding(character: Node3D, local_player: bool) -> void:
	var is_mp := multiplayer.multiplayer_peer != null
	var is_server := is_mp and multiplayer.is_server()
	var character_peer_id: int = character.peer_id
	var local_bot_authority := _is_bot_peer(character_peer_id) and not is_mp

	# State binding: whoever simulates a plane authoritatively rebroadcasts its
	# state. The server simulates every plane; in single player the handler
	# no-ops, so the old local/bot binding is kept for symmetry.
	var local_state_callback := Callable(self, "_on_local_character_state_changed")
	var state_connected: bool = character.local_state_changed.is_connected(local_state_callback)
	var should_bind_state := is_server or (not is_mp and (local_player or local_bot_authority))

	if should_bind_state and not state_connected:
		character.local_state_changed.connect(local_state_callback)
	elif not should_bind_state and state_connected:
		character.local_state_changed.disconnect(local_state_callback)

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
			_configure_bot_behavior(character, character_peer_id)

		if local_player and character_type == CharacterType.PLANE:
			_bind_local_plane_presentation(character)

	_update_local_plane_presentation_binding()


func _is_peer_world_ready(peer_id: int) -> bool:
	if peer_id == multiplayer.get_unique_id():
		return true

	return bool(_world_ready_peers.get(peer_id, false))


func _broadcast_character_state(peer_id: int, snapshot: Dictionary) -> void:
	# The owner gets its own state echoed back: the ack_seq in the snapshot is
	# what drives client-side reconciliation.
	for target_peer_id in multiplayer.get_peers():
		if not _is_peer_world_ready(target_peer_id):
			continue

		apply_character_state.rpc_id(target_peer_id, peer_id, snapshot)


func _broadcast_despawn(peer_id: int) -> void:
	for target_peer_id in multiplayer.get_peers():
		if not _is_peer_world_ready(target_peer_id):
			continue

		despawn_character.rpc_id(target_peer_id, peer_id)


func _bind_character_health_replication(character: Node3D, peer_id: int) -> void:
	var health = character.get_health_component()
	if health == null:
		return

	var damaged_callback := Callable(self, "_on_character_damaged").bind(peer_id)
	if not health.damaged.is_connected(damaged_callback):
		health.damaged.connect(damaged_callback)

	var shot_down_callback := Callable(self, "_on_character_shot_down").bind(peer_id)
	if not health.shot_down.is_connected(shot_down_callback):
		health.shot_down.connect(shot_down_callback)


func _sync_health_states_to_peer(target_peer_id: int) -> void:
	for peer_id in _sorted_peer_ids():
		var health = _get_character_health(peer_id)
		if health == null:
			continue

		cl_health_changed.rpc_id(target_peer_id, peer_id, health.current_hp)
		if _is_character_shot_down(peer_id):
			cl_shot_down.rpc_id(target_peer_id, peer_id)


func _get_character_health(peer_id: int):
	var character := _characters.get_node_or_null(_character_name(peer_id))
	if character == null:
		return null

	return character.get_health_component()


func _is_character_shot_down(peer_id: int) -> bool:
	var character := _characters.get_node_or_null(_character_name(peer_id))
	if character == null:
		return false

	return character.is_shot_down


func _on_character_damaged(_amount: float, current_hp: float, peer_id: int) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	for target_peer_id in multiplayer.get_peers():
		if _is_peer_world_ready(target_peer_id):
			cl_health_changed.rpc_id(target_peer_id, peer_id, current_hp)


func _on_character_shot_down(peer_id: int) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	for target_peer_id in multiplayer.get_peers():
		if _is_peer_world_ready(target_peer_id):
			cl_health_changed.rpc_id(target_peer_id, peer_id, 0.0)
			cl_shot_down.rpc_id(target_peer_id, peer_id)


@rpc("authority", "reliable")
func cl_health_changed(peer_id: int, current_hp: float) -> void:
	var health = _get_character_health(peer_id)
	if health == null:
		return

	health.apply_current_hp_from_network(current_hp)


@rpc("authority", "reliable")
func cl_shot_down(peer_id: int) -> void:
	var health = _get_character_health(peer_id)
	if health != null:
		health.apply_shot_down_from_network()

	var character := _characters.get_node_or_null(_character_name(peer_id))
	if character != null:
		character.apply_remote_shot_down()


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


func _physics_process(_delta: float) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	for peer_id in _gun_cooldowns.keys():
		var cooldown := maxf(float(_gun_cooldowns[peer_id]) - _delta, 0.0)
		if cooldown <= 0.0:
			_gun_cooldowns.erase(peer_id)
		else:
			_gun_cooldowns[peer_id] = cooldown
	for peer_id in _missile_cooldowns.keys():
		var cooldown := maxf(float(_missile_cooldowns[peer_id]) - _delta, 0.0)
		if cooldown <= 0.0:
			_missile_cooldowns.erase(peer_id)
		else:
			_missile_cooldowns[peer_id] = cooldown


func _on_projectile_entered(node: Node) -> void:
	if not multiplayer.is_server():
		return
	var missile := node as Missile
	if missile == null:
		return
	var missile_id := _next_missile_id
	_next_missile_id += 1
	_active_missiles[missile_id] = missile
	var vel := missile.linear_velocity
	var target_peer_id := -1
	var plane_target := missile.target as PlaneCharacter
	if plane_target != null and is_instance_valid(plane_target):
		target_peer_id = plane_target.peer_id
	missile.died.connect(
		func(exploded: bool, pos: Vector3) -> void: _on_missile_died(missile_id, exploded, pos)
	)
	for peer_id in multiplayer.get_peers():
		if _is_peer_world_ready(peer_id):
			cl_spawn_missile.rpc_id(peer_id, missile_id, missile.global_transform, vel, target_peer_id)


func _on_missile_died(missile_id: int, exploded: bool, pos: Vector3) -> void:
	_active_missiles.erase(missile_id)
	for peer_id in multiplayer.get_peers():
		if _is_peer_world_ready(peer_id):
			cl_despawn_missile.rpc_id(peer_id, missile_id, exploded, pos)


func _server_fire_missile(firing_plane: Node3D, locked_target: Node3D) -> void:
	var missile := MISSILE_SCENE.instantiate() as Missile
	var launcher = firing_plane.get_missile_launcher_component()
	if launcher != null:
		missile.global_transform = launcher.get_and_advance_launch_transform(firing_plane)
	else:
		missile.global_transform = firing_plane.global_transform
	missile.target = locked_target
	missile.host = firing_plane
	missile.linear_velocity = firing_plane.linear_velocity
	_projectiles.add_child(missile)
	missile.add_collision_exception_with(firing_plane)


func _server_fire_autocannon(plane: Node3D, firing_peer_id: int, target_peer_id: int = -1) -> void:
	var autocannon = plane.get_autocannon_component()
	if autocannon == null or not is_instance_valid(autocannon):
		return

	var desired_target := _resolve_autocannon_target(plane, target_peer_id)

	var aim_direction := AUTOCANNON_SCRIPT.compute_aim_direction(
		plane,
		desired_target,
		autocannon.bullet_speed,
		autocannon.lead_cone_half_angle_deg
	)

	var bullet = BULLET_SCENE.instantiate()
	bullet.shooter = plane
	bullet.damage = autocannon.damage
	_projectiles.add_child(bullet)
	var launch_velocity: Vector3 = aim_direction * autocannon.bullet_speed + plane.linear_velocity
	bullet.initialize_launch(plane.global_position, launch_velocity)

	var bullet_id := _next_bullet_id
	_next_bullet_id += 1
	_active_bullets[bullet_id] = bullet
	_gun_cooldowns[firing_peer_id] = autocannon.fire_cooldown

	bullet.died.connect(func(hit: bool, pos: Vector3) -> void: _on_bullet_died(hit, pos, bullet_id))

	for peer_id in multiplayer.get_peers():
		if _is_peer_world_ready(peer_id):
			cl_spawn_bullet.rpc_id(peer_id, bullet_id, bullet.global_position, bullet.linear_velocity)


func _resolve_autocannon_target(plane: Node3D, target_peer_id: int) -> Node3D:
	if target_peer_id < 0:
		return null

	var target := _characters.get_node_or_null(_character_name(target_peer_id))
	if target == null or not is_instance_valid(target):
		return null
	if target.is_shot_down:
		return null

	var weapon_lock = plane.get_weapon_lock_component()
	if weapon_lock == null or not is_instance_valid(weapon_lock):
		return null
	if not weapon_lock.is_target_in_envelope(target):
		return null

	return target


func _resolve_missile_target(plane: Node3D, target_peer_id: int) -> Node3D:
	if target_peer_id < 0:
		return null

	var target := _characters.get_node_or_null(_character_name(target_peer_id))
	if target == null or not is_instance_valid(target):
		return null
	if target.is_shot_down:
		return null

	var weapon_lock = plane.get_weapon_lock_component()
	if weapon_lock == null or not is_instance_valid(weapon_lock):
		return null
	if not weapon_lock.is_target_in_envelope(target):
		return null

	return target


func _on_bullet_died(_hit: bool, pos: Vector3, bullet_id: int) -> void:
	_active_bullets.erase(bullet_id)
	for peer_id in multiplayer.get_peers():
		if _is_peer_world_ready(peer_id):
			cl_despawn_bullet.rpc_id(peer_id, bullet_id, pos)


@rpc("any_peer", "reliable")
func sv_request_fire_missile(firing_peer_id: int, target_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != firing_peer_id:
		return
	var firing_plane := _characters.get_node_or_null(_character_name(firing_peer_id))
	if firing_plane == null or not is_instance_valid(firing_plane):
		return
	if firing_plane.is_shot_down:
		return
	var cooldown := float(_missile_cooldowns.get(firing_peer_id, 0.0))
	if cooldown > 0.0:
		return
	var locked_target := _resolve_missile_target(firing_plane, target_peer_id)
	var launcher = firing_plane.get_missile_launcher_component()
	if launcher != null and is_instance_valid(launcher):
		_missile_cooldowns[firing_peer_id] = launcher.fire_cooldown
	_server_fire_missile(firing_plane, locked_target)


@rpc("any_peer", "reliable")
func sv_request_fire_autocannon(firing_peer_id: int, target_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != firing_peer_id:
		return
	var plane := _characters.get_node_or_null(_character_name(firing_peer_id))
	if plane == null or not is_instance_valid(plane):
		return
	if plane.is_shot_down:
		return
	var cooldown := float(_gun_cooldowns.get(firing_peer_id, 0.0))
	if cooldown > 0.0:
		return
	_server_fire_autocannon(plane, firing_peer_id, target_peer_id)


@rpc("authority", "reliable")
func cl_spawn_missile(missile_id: int, t: Transform3D, velocity: Vector3, target_peer_id: int) -> void:
	if multiplayer.is_server():
		return
	var missile := MISSILE_SCENE.instantiate() as Missile
	missile.init_replica(t, velocity, _resolve_remote_missile_target(target_peer_id))
	_projectiles.add_child(missile)
	_remote_missiles[missile_id] = missile


@rpc("authority", "call_remote", "reliable", 0)
func cl_spawn_bullet(bullet_id: int, pos: Vector3, vel: Vector3) -> void:
	if multiplayer.is_server():
		return
	var visual = BULLET_VISUAL_SCENE.instantiate()
	_projectiles.add_child(visual)
	visual.init(pos, vel)
	_active_bullet_visuals[bullet_id] = visual


@rpc("authority", "reliable")
func cl_despawn_missile(missile_id: int, exploded: bool, pos: Vector3) -> void:
	if multiplayer.is_server():
		return
	var visual = _remote_missiles.get(missile_id)
	if visual != null and is_instance_valid(visual):
		if exploded:
			var explosion := EXPLOSION_SCENE.instantiate() as Node3D
			_projectiles.add_child(explosion)
			explosion.global_position = pos
		visual.despawn(pos)
	_remote_missiles.erase(missile_id)


func _resolve_remote_missile_target(target_peer_id: int) -> Node3D:
	if target_peer_id < 0:
		return null
	return _characters.get_node_or_null(_character_name(target_peer_id)) as Node3D


@rpc("authority", "call_remote", "reliable", 0)
func cl_despawn_bullet(bullet_id: int, pos: Vector3) -> void:
	if multiplayer.is_server():
		return
	var visual = _active_bullet_visuals.get(bullet_id)
	if visual != null and is_instance_valid(visual):
		visual.despawn(pos)
	_active_bullet_visuals.erase(bullet_id)


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
