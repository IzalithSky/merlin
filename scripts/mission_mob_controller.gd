class_name MissionMobController
extends Node3D

const DEFAULT_PLANE_SPEED := 100.0
const DEFAULT_ZEPPELIN_SPEED := 30.0
const TERRAIN_RAY_HEIGHT := 5000.0
const GROUND_AA_SCENE := preload("res://scenes/ground_aa_unit.tscn")
const GROUND_SAM_SCENE := preload("res://scenes/ground_sam_unit.tscn")
const ZEPPELIN_SCENE := preload("res://scenes/zeppelin.tscn")

const GROUND_MOB_SCENES := {
	"ground_aa": GROUND_AA_SCENE,
	"ground_sam": GROUND_SAM_SCENE,
}

const AIR_MOB_SCENES := {
	"zeppelin": ZEPPELIN_SCENE,
}

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
	if not _has_spawn_authority():
		return nodes
	var type_id := String(spec.get("type", ""))
	if type_id.is_empty():
		push_error("Mission mob spec is missing type.")
		return nodes

	var count := maxi(int(spec.get("count", 1)), 0)
	if count <= 0:
		return nodes

	for index in range(count):
		var spawn_position: Variant = _resolve_spec_position(spec)
		if spawn_position == null:
			push_error("Mission mob spec '%s' is missing position/area for instance %d." % [type_id, index])
			continue

		if GROUND_MOB_SCENES.has(type_id):
			var team := int(spec.get("team", 0))
			var ground_position := spawn_position as Vector3
			var ground_node := spawn_ground_unit(type_id, team, Vector2(ground_position.x, ground_position.z), _get_spec_overrides(spec))
			if ground_node != null:
				nodes.append(ground_node)
			continue

		if AIR_MOB_SCENES.has(type_id):
			var air_node := _spawn_air_mob(type_id, spec, spawn_position as Vector3)
			if air_node != null:
				nodes.append(air_node)
			continue

		push_error("Mission mob type '%s' is not implemented yet." % type_id)
		break
	return nodes


func spawn_player(peer_id: int, spawn_position: Vector3, yaw := 0.0, speed := DEFAULT_PLANE_SPEED) -> Node:
	if not _has_spawn_authority():
		return null
	if _spawner == null:
		_spawner = _find_spawner()
	if _spawner == null:
		return null
	return _spawner.spawn_player_character(peer_id, spawn_position, yaw, speed)


func spawn_ground_unit(type_id: String, team: int, xz: Vector2, overrides := {}) -> Node:
	if not _has_spawn_authority():
		return null
	if not GROUND_MOB_SCENES.has(type_id):
		push_error("Unknown ground mob type '%s'." % type_id)
		return null
	if _mobs == null:
		return null

	var node := (GROUND_MOB_SCENES[type_id] as PackedScene).instantiate() as Node3D
	if node == null:
		return null
	node.global_position = Vector3(xz.x, 0.0, xz.y)
	if _has_property(node, "team_id"):
		node.set("team_id", team)
	_apply_overrides(node, overrides)
	_mobs.add_child(node, true)
	return node


func spawn_zeppelin(team: int, spawn_position: Vector3, overrides := {}) -> Node:
	if not _has_spawn_authority() or _mobs == null:
		return null

	var node := ZEPPELIN_SCENE.instantiate() as Node3D
	if node == null:
		return null
	node.global_position = _clamp_air_position_above_terrain(spawn_position)
	if _has_property(node, "team_id"):
		node.set("team_id", team)
	if _has_property(node, "speed") and not overrides.has("speed"):
		node.set("speed", DEFAULT_ZEPPELIN_SPEED)
	_apply_overrides(node, overrides)
	_mobs.add_child(node, true)
	return node


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


func random_point_in_area(area: Variant) -> Vector3:
	var parsed_area := _parse_area(area)
	if parsed_area.is_empty():
		return Vector3.ZERO
	var area_min: Vector3 = parsed_area["min"]
	var area_max: Vector3 = parsed_area["max"]
	return Vector3(
		_rng.randf_range(area_min.x, area_max.x),
		_rng.randf_range(area_min.y, area_max.y),
		_rng.randf_range(area_min.z, area_max.z)
	)


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


func _resolve_spec_position(spec: Dictionary) -> Variant:
	if spec.has("position"):
		return _parse_vector3(spec.get("position"))
	if spec.has("area"):
		var area_position := random_point_in_area(spec.get("area"))
		if area_position == Vector3.ZERO and _parse_area(spec.get("area")).is_empty():
			return null
		return area_position
	return null


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

	var spawn_position: Variant = _parse_vector3(spec.get("position"))
	if spawn_position == null:
		push_error("Mission player position is invalid.")
		return {}

	return {
		"position": spawn_position,
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


func _parse_area(area: Variant) -> Dictionary:
	if area is String:
		var named_areas: Variant = _mission_config.get("areas", {})
		if not named_areas is Dictionary:
			return {}
		var named_area: Variant = (named_areas as Dictionary).get(String(area), {})
		if not named_area is Dictionary:
			return {}
		return _parse_area(named_area)

	if not area is Dictionary:
		return {}

	var area_dict := area as Dictionary
	if area_dict.has("min") and area_dict.has("max"):
		var area_min: Variant = _parse_vector3(area_dict.get("min"))
		var area_max: Variant = _parse_vector3(area_dict.get("max"))
		if area_min == null or area_max == null:
			return {}
		return {
			"min": Vector3(
				minf((area_min as Vector3).x, (area_max as Vector3).x),
				minf((area_min as Vector3).y, (area_max as Vector3).y),
				minf((area_min as Vector3).z, (area_max as Vector3).z)
			),
			"max": Vector3(
				maxf((area_min as Vector3).x, (area_max as Vector3).x),
				maxf((area_min as Vector3).y, (area_max as Vector3).y),
				maxf((area_min as Vector3).z, (area_max as Vector3).z)
			),
		}

	if area_dict.has("center") and area_dict.has("size"):
		var center: Variant = _parse_vector3(area_dict.get("center"))
		var size: Variant = _parse_vector3(area_dict.get("size"))
		if center == null or size == null:
			return {}
		var half_size := (size as Vector3) * 0.5
		return {
			"min": (center as Vector3) - half_size,
			"max": (center as Vector3) + half_size,
		}

	return {}


func _get_spec_overrides(spec: Dictionary) -> Dictionary:
	var overrides: Variant = spec.get("overrides", {})
	if overrides is Dictionary:
		return (overrides as Dictionary).duplicate(true)
	return {}


func _spawn_air_mob(type_id: String, spec: Dictionary, spawn_position: Vector3) -> Node:
	var team := int(spec.get("team", 0))
	var overrides := _get_spec_overrides(spec)
	var clamped_position := _clamp_air_position_above_terrain(spawn_position)
	match type_id:
		"zeppelin":
			if not overrides.has("speed") and spec.has("speed"):
				overrides["speed"] = float(spec.get("speed", DEFAULT_ZEPPELIN_SPEED))
			return spawn_zeppelin(team, clamped_position, overrides)
	return null


func _clamp_air_position_above_terrain(spawn_position: Vector3) -> Vector3:
	var space_state := get_world_3d().direct_space_state
	var ray_start := spawn_position + Vector3.UP * TERRAIN_RAY_HEIGHT
	var ray_end := spawn_position + Vector3.DOWN * TERRAIN_RAY_HEIGHT
	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end, 1)
	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return spawn_position
	var hit_position: Vector3 = result["position"]
	if spawn_position.y >= hit_position.y:
		return spawn_position
	return Vector3(spawn_position.x, hit_position.y, spawn_position.z)


func _apply_overrides(node: Node, overrides: Dictionary) -> void:
	for key in overrides.keys():
		if not _has_property(node, String(key)):
			push_error("Override '%s' is not a property on %s." % [String(key), node.name])
			continue
		node.set(String(key), overrides[key])


func _has_property(node: Object, property_name: String) -> bool:
	for property_info in node.get_property_list():
		if String(property_info.get("name", "")) == property_name:
			return true
	return false


func _has_spawn_authority() -> bool:
	return multiplayer.multiplayer_peer == null or multiplayer.is_server()
