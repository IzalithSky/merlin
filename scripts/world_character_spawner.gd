extends Node3D

const PLAYER_CHARACTER_SCENE := preload("res://scenes/player_character.tscn")
const PLANE_CHARACTER_SCENE := preload("res://scenes/plane_character.tscn")
const LOCAL_PLANE_CAMERA_RIG_SCENE := preload("res://scenes/local_plane_camera_rig.tscn")
const PLANE_TELEMETRY_HUD_SCENE := preload("res://scenes/plane_telemetry_hud.tscn")
const PLANE_BOT_PILOT_SCRIPT := preload("res://scripts/plane_bot_pilot.gd")
const CHARACTER_NAME_PREFIX := "PlayerCharacter_"
const BOT_PEER_ID_BASE := 1000000

enum CharacterType {
	CAMERA_CUBE,
	PLANE,
}

@export var spawn_center := Vector3.ZERO
@export var spawn_height_offset: float = 500.0
@export var spawn_radius := 240.0
@export var late_join_spawn_min_radius := 300.0
@export var late_join_spawn_max_radius := 600.0
@export var character_type := CharacterType.PLANE
@export var bot_count := 1
@export var bot_spawn_radius := 1200.0
@export var bot_follow_target_path: NodePath = NodePath("level/BotFollowTarget")
@export var bot_orbit_range := 900.0
@export var bot_orbit_tolerance := 140.0

@onready var _characters: Node3D = $characters

var _peer_spawn_states: Dictionary = {}
var _world_ready_peers: Dictionary = {}
var _spawn_random := RandomNumberGenerator.new()
var _local_plane_camera_rig: Node3D
var _local_plane_hud: CanvasLayer
var _bot_follow_target: Node3D


func _ready() -> void:
	_spawn_random.randomize()
	_resolve_bot_follow_target()
	DisplaySettings.settings_changed.connect(_on_display_settings_changed)

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
	if character_type != CharacterType.PLANE:
		return

	var bot_peer := _is_bot_peer(peer_id)
	var bot_active := bot_peer and (multiplayer.multiplayer_peer == null or multiplayer.is_server())
	if character.has_method("set_bot_controlled"):
		character.call("set_bot_controlled", bot_active)

	if not bot_active:
		var active_pilot := character.get_node_or_null("PlaneBotPilot")
		if active_pilot != null:
			active_pilot.queue_free()
		return

	if _bot_follow_target == null:
		_resolve_bot_follow_target()

	var pilot_node := character.get_node_or_null("PlaneBotPilot")
	if pilot_node == null:
		pilot_node = PLANE_BOT_PILOT_SCRIPT.new()
		pilot_node.name = "PlaneBotPilot"
		character.add_child(pilot_node)

	pilot_node.set("desired_range", bot_orbit_range)
	pilot_node.set("range_tolerance", bot_orbit_tolerance)

	if pilot_node.has_method("set_follow_target"):
		pilot_node.call("set_follow_target", _bot_follow_target)


func _is_bot_peer(peer_id: int) -> bool:
	if bot_count <= 0:
		return false

	return peer_id >= BOT_PEER_ID_BASE and peer_id < BOT_PEER_ID_BASE + bot_count


func _spawn_character(peer_id: int, local_player: bool, character_position: Vector3, yaw: float) -> Node3D:
	var existing := _characters.get_node_or_null(_character_name(peer_id))
	if existing != null:
		existing.configure(peer_id, local_player)
		_set_character_local_binding(existing, local_player)
		_configure_bot_behavior(existing, peer_id)
		_apply_display_settings_to_character(existing)
		if local_player:
			_bind_local_plane_presentation(existing)
		return existing

	var character := _get_character_scene().instantiate() as Node3D
	character.name = _character_name(peer_id)
	character.position = character_position
	character.rotation.y = yaw
	character.configure(peer_id, local_player)
	_set_character_local_binding(character, local_player)
	_configure_bot_behavior(character, peer_id)
	_characters.add_child(character, true)
	_apply_display_settings_to_character(character)
	if local_player:
		_bind_local_plane_presentation(character)
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


func _on_local_character_state_changed(peer_id: int, character_position: Vector3, yaw: float, pitch: float, roll: float) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.is_server():
		_broadcast_character_state(peer_id, character_position, yaw, pitch, roll)
	else:
		submit_character_state.rpc_id(1, character_position, yaw, pitch, roll)


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
	_spawn_peer_character_locally(sender_id)
	_sync_spawn_states_to_peer(sender_id)

	if is_new_peer:
		_broadcast_spawn_state(sender_id, sender_id)


@rpc("authority", "reliable")
func spawn_character(peer_id: int, character_position: Vector3, yaw: float) -> void:
	_spawn_character(peer_id, _is_local_peer(peer_id), character_position, yaw)
	_enforce_local_ownership()


@rpc("authority", "reliable")
func despawn_character(peer_id: int) -> void:
	_despawn_character(peer_id)


@rpc("any_peer", "call_remote", "unreliable", 1)
func submit_character_state(character_position: Vector3, yaw: float, pitch: float, roll: float) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	_apply_character_state_locally(sender_id, character_position, yaw, pitch, roll)
	_broadcast_character_state(sender_id, character_position, yaw, pitch, roll)


@rpc("authority", "call_remote", "unreliable", 2)
func apply_character_state(peer_id: int, character_position: Vector3, yaw: float, pitch: float, roll: float) -> void:
	if peer_id == multiplayer.get_unique_id():
		return

	_apply_character_state_locally(peer_id, character_position, yaw, pitch, roll)


func _apply_character_state_locally(peer_id: int, character_position: Vector3, yaw: float, pitch: float, roll: float) -> void:
	var character := _characters.get_node_or_null(_character_name(peer_id))
	if character == null:
		return

	character.apply_remote_state(character_position, yaw, pitch, roll)


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
	var local_state_callback := Callable(self, "_on_local_character_state_changed")
	var signal_connected: bool = character.local_state_changed.is_connected(local_state_callback)
	var character_peer_id := int(character.get("peer_id"))
	var local_bot_authority := _is_bot_peer(character_peer_id) and (
		multiplayer.multiplayer_peer == null or multiplayer.is_server()
	)
	var should_bind := local_player or local_bot_authority

	if should_bind and not signal_connected:
		character.local_state_changed.connect(local_state_callback)
	elif not should_bind and signal_connected:
		character.local_state_changed.disconnect(local_state_callback)


func _enforce_local_ownership() -> void:
	if multiplayer.multiplayer_peer == null:
		return

	var local_peer_id := multiplayer.get_unique_id()
	for character in _characters.get_children():
		var character_peer_id := int(character.get("peer_id"))
		var local_player := character_peer_id == local_peer_id
		character.configure(character_peer_id, local_player)
		_set_character_local_binding(character, local_player)
		_configure_bot_behavior(character, character_peer_id)

		if local_player:
			_bind_local_plane_presentation(character)

	_update_local_plane_presentation_binding()


func _is_peer_world_ready(peer_id: int) -> bool:
	if peer_id == multiplayer.get_unique_id():
		return true

	return bool(_world_ready_peers.get(peer_id, false))


func _broadcast_character_state(peer_id: int, character_position: Vector3, yaw: float, pitch: float, roll: float) -> void:
	for target_peer_id in multiplayer.get_peers():
		if target_peer_id == peer_id or not _is_peer_world_ready(target_peer_id):
			continue

		apply_character_state.rpc_id(target_peer_id, peer_id, character_position, yaw, pitch, roll)


func _broadcast_despawn(peer_id: int) -> void:
	for target_peer_id in multiplayer.get_peers():
		if not _is_peer_world_ready(target_peer_id):
			continue

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
	if local_character == null:
		_clear_local_plane_presentation_target()
		return

	_bind_local_plane_presentation(local_character)


func _find_local_character() -> Node3D:
	var local_peer_id := 1
	if multiplayer.multiplayer_peer != null:
		local_peer_id = multiplayer.get_unique_id()

	for character in _characters.get_children():
		if int(character.get("peer_id")) == local_peer_id:
			return character

	return null


func _bind_local_plane_presentation(character: Node3D) -> void:
	if character_type != CharacterType.PLANE:
		return

	_ensure_local_plane_presentation()

	if _local_plane_camera_rig != null and _local_plane_camera_rig.has_method("set_target"):
		_local_plane_camera_rig.call("set_target", character)

	if _local_plane_hud != null and _local_plane_hud.has_method("set_target"):
		_local_plane_hud.call("set_target", character)


func _ensure_local_plane_presentation() -> void:
	if _local_plane_camera_rig == null:
		_local_plane_camera_rig = LOCAL_PLANE_CAMERA_RIG_SCENE.instantiate() as Node3D
		add_child(_local_plane_camera_rig)

	if _local_plane_hud == null:
		_local_plane_hud = PLANE_TELEMETRY_HUD_SCENE.instantiate() as CanvasLayer
		add_child(_local_plane_hud)


func _clear_local_plane_presentation_target() -> void:
	if _local_plane_camera_rig != null and _local_plane_camera_rig.has_method("set_target"):
		_local_plane_camera_rig.call("set_target", null)

	if _local_plane_hud != null and _local_plane_hud.has_method("set_target"):
		_local_plane_hud.call("set_target", null)


func _on_display_settings_changed() -> void:
	for character in _characters.get_children():
		_apply_display_settings_to_character(character)


func _apply_display_settings_to_character(character: Node) -> void:
	if _has_property(character, "debug_force_vectors_enabled"):
		character.set("debug_force_vectors_enabled", DisplaySettings.debug_force_arrows_enabled)

	if DisplaySettings.debug_force_arrows_enabled and character.has_method("_ensure_force_debug_renderer"):
		character.call("_ensure_force_debug_renderer")

	if character.has_method("_update_force_debug_renderer_state"):
		character.call("_update_force_debug_renderer_state")


func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true

	return false
