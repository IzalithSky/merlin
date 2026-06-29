class_name MissionMobController
extends Node3D

const DEFAULT_PLANE_SPEED := 100.0

@export var mission_config_path := ""

var _spawner: WorldCharacterSpawner = null
var _bootstrapped := false
var _mission_config: Dictionary = {}
var _rng := RandomNumberGenerator.new()
@onready var _mobs: Node3D = get_node_or_null("../mobs") as Node3D


func _ready() -> void:
	add_to_group("mission_mob_controller")
	_rng.randomize()
	call_deferred("_bootstrap_default_session")


func set_mission_config_path(path: String) -> void:
	mission_config_path = path


func load_mission_file(path: String) -> Error:
	if path.is_empty():
		_mission_config = {}
		return ERR_INVALID_PARAMETER

	var config := _read_json(path)
	if config.is_empty():
		return ERR_PARSE_ERROR

	load_mission(config)
	return OK


func load_mission(config: Dictionary) -> void:
	_mission_config = config.duplicate(true)
	if _mission_config.has("seed"):
		_rng.seed = int(_mission_config["seed"])
	else:
		_rng.randomize()


func spawn_from_spec(spec: Dictionary) -> Array[Node]:
	var nodes: Array[Node] = []
	var type_id := String(spec.get("type", ""))
	if type_id.is_empty():
		push_error("Mission mob spec is missing type.")
		return nodes

	push_error("Mission mob type '%s' is not implemented yet." % type_id)
	return nodes


func spawn_player(peer_id: int, position: Vector3, yaw := 0.0, speed := DEFAULT_PLANE_SPEED) -> Node:
	if not _has_spawn_authority():
		return null
	if _spawner == null:
		_spawner = _find_spawner()
	if _spawner == null:
		return null
	return _spawner.spawn_player_character(peer_id, position, yaw, speed)


func clear_mobs() -> void:
	if _mobs == null:
		return
	for child in _mobs.get_children():
		child.queue_free()


func get_mobs() -> Array[Node]:
	if _mobs == null:
		return []
	var nodes: Array[Node] = []
	for child in _mobs.get_children():
		nodes.append(child)
	return nodes


func _bootstrap_default_session() -> void:
	if _bootstrapped:
		return
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return
	_spawner = _find_spawner()
	if _spawner == null:
		return
	if not mission_config_path.is_empty():
		load_mission_file(mission_config_path)
	_bootstrapped = true
	_bootstrap_players()


func _find_spawner() -> WorldCharacterSpawner:
	var parent := get_parent()
	if parent != null:
		var sibling := parent.get_node_or_null("WorldCharacterSpawner") as WorldCharacterSpawner
		if sibling != null:
			return sibling
	var nodes := get_tree().get_nodes_in_group("world_character_spawner")
	if nodes.is_empty():
		return null
	return nodes[0] as WorldCharacterSpawner


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("Mission file not found: %s." % path)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Could not open mission file %s (error %s)." % [path, FileAccess.get_open_error()])
		return {}

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		push_error("Mission file is not a Dictionary JSON payload: %s." % path)
		return {}

	return (parsed as Dictionary).duplicate(true)


func _bootstrap_players() -> void:
	var player_specs := _get_player_spawn_specs()
	if multiplayer.multiplayer_peer == null:
		if player_specs.is_empty():
			_spawner.begin_default_session()
			return
		_spawner.begin_single_player_session_from_state(_build_player_spawn_state(player_specs[0]))
		return

	if player_specs.is_empty():
		_spawner.begin_default_session()
		return
	_spawner.begin_server_session_from_player_specs(player_specs)


func _get_player_spawn_specs() -> Array[Dictionary]:
	var specs: Array[Dictionary] = []
	var raw_players: Variant = _mission_config.get("players", [])
	if not raw_players is Array:
		return specs

	for player_variant in raw_players:
		if not player_variant is Dictionary:
			push_error("Mission player entry must be a Dictionary.")
			continue
		var player_spec := _parse_player_spec(player_variant as Dictionary)
		if player_spec.is_empty():
			continue
		specs.append(player_spec)
	return specs


func _parse_player_spec(spec: Dictionary) -> Dictionary:
	if not spec.has("position"):
		push_error("Mission player entry is missing position.")
		return {}

	var position: Variant = _parse_vector3(spec.get("position"))
	if position == null:
		push_error("Mission player position is invalid.")
		return {}

	return {
		"position": position,
		"yaw": float(spec.get("yaw", 0.0)),
		"speed": float(spec.get("speed", DEFAULT_PLANE_SPEED)),
	}


func _build_player_spawn_state(spec: Dictionary) -> Dictionary:
	return {
		"character_position": spec["position"],
		"yaw": float(spec.get("yaw", 0.0)),
		"forward_speed": float(spec.get("speed", DEFAULT_PLANE_SPEED)),
	}


func _parse_vector3(value: Variant) -> Variant:
	if value is Vector3:
		return value
	if not value is Array:
		return null
	var parts: Array = value
	if parts.size() < 3:
		return null
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))


func _has_spawn_authority() -> bool:
	return multiplayer.multiplayer_peer == null or multiplayer.is_server()
