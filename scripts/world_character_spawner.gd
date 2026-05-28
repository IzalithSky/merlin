extends Node3D

const PLAYER_CHARACTER_SCENE := preload("res://scenes/player_character.tscn")
const CHARACTER_NAME_PREFIX := "PlayerCharacter_"

@export var spawn_center := Vector3(-4000.0, 7000.0, 18000.0)
@export var spawn_radius := 240.0
@export var late_join_spawn_min_radius := 300.0
@export var late_join_spawn_max_radius := 600.0

@onready var _characters: Node3D = $characters

var _peer_spawn_states: Dictionary = {}
var _world_ready_peers: Dictionary = {}
var _spawn_random := RandomNumberGenerator.new()


func _ready() -> void:
	_spawn_random.randomize()

	if multiplayer.multiplayer_peer == null:
		var spawn_state := _build_radial_spawn_state(0, 1)
		_spawn_character(1, true, spawn_state["character_position"], spawn_state["yaw"])
		return

	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_world_ready_peers[multiplayer.get_unique_id()] = true
		_register_initial_peers()
		_spawn_registered_characters_locally()
	else:
		request_world_sync.rpc_id(1)


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


func _spawn_character(peer_id: int, local_player: bool, character_position: Vector3, yaw: float) -> Node3D:
	var existing := _characters.get_node_or_null(_character_name(peer_id))
	if existing != null:
		existing.configure(peer_id, local_player)
		_set_character_local_binding(existing, local_player)
		return existing

	var character := PLAYER_CHARACTER_SCENE.instantiate() as Node3D
	character.name = _character_name(peer_id)
	character.position = character_position
	character.rotation.y = yaw
	character.configure(peer_id, local_player)
	_set_character_local_binding(character, local_player)
	_characters.add_child(character, true)
	return character


func _despawn_character(peer_id: int) -> void:
	var character := _characters.get_node_or_null(_character_name(peer_id))
	if character != null:
		character.queue_free()


func _character_name(peer_id: int) -> String:
	return "%s%d" % [CHARACTER_NAME_PREFIX, peer_id]


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return

	_despawn_character(peer_id)
	_peer_spawn_states.erase(peer_id)
	_world_ready_peers.erase(peer_id)
	_broadcast_despawn(peer_id)


func _on_local_character_state_changed(peer_id: int, character_position: Vector3, yaw: float, pitch: float) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	if multiplayer.is_server():
		_broadcast_character_state(peer_id, character_position, yaw, pitch)
	else:
		submit_character_state.rpc_id(1, character_position, yaw, pitch)


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
func submit_character_state(character_position: Vector3, yaw: float, pitch: float) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	_apply_character_state_locally(sender_id, character_position, yaw, pitch)
	_broadcast_character_state(sender_id, character_position, yaw, pitch)


@rpc("authority", "call_remote", "unreliable", 2)
func apply_character_state(peer_id: int, character_position: Vector3, yaw: float, pitch: float) -> void:
	if peer_id == multiplayer.get_unique_id():
		return

	_apply_character_state_locally(peer_id, character_position, yaw, pitch)


func _apply_character_state_locally(peer_id: int, character_position: Vector3, yaw: float, pitch: float) -> void:
	var character := _characters.get_node_or_null(_character_name(peer_id))
	if character == null:
		return

	character.apply_remote_state(character_position, yaw, pitch)


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
	var character_position := spawn_center + Vector3(sin(angle) * radius, 0.0, cos(angle) * radius)

	return {
		"character_position": character_position,
		"yaw": _yaw_towards(character_position, spawn_center)
	}


func _build_late_join_spawn_state() -> Dictionary:
	var min_radius: float = max(late_join_spawn_min_radius, 0.0)
	var max_radius: float = max(late_join_spawn_max_radius, min_radius)
	var angle: float = _spawn_random.randf_range(0.0, TAU)
	var radius: float = _spawn_random.randf_range(min_radius, max_radius)
	var character_position := spawn_center + Vector3(sin(angle) * radius, 0.0, cos(angle) * radius)

	return {
		"character_position": character_position,
		"yaw": _yaw_towards(character_position, spawn_center)
	}


func _is_local_peer(peer_id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return false

	return peer_id == multiplayer.get_unique_id()


func _set_character_local_binding(character: Node3D, local_player: bool) -> void:
	var local_state_callback := Callable(self, "_on_local_character_state_changed")
	var signal_connected: bool = character.local_state_changed.is_connected(local_state_callback)

	if local_player and not signal_connected:
		character.local_state_changed.connect(local_state_callback)
	elif not local_player and signal_connected:
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


func _is_peer_world_ready(peer_id: int) -> bool:
	if peer_id == multiplayer.get_unique_id():
		return true

	return bool(_world_ready_peers.get(peer_id, false))


func _broadcast_character_state(peer_id: int, character_position: Vector3, yaw: float, pitch: float) -> void:
	for target_peer_id in multiplayer.get_peers():
		if target_peer_id == peer_id or not _is_peer_world_ready(target_peer_id):
			continue

		apply_character_state.rpc_id(target_peer_id, peer_id, character_position, yaw, pitch)


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
