extends Node3D

const WORLD_SCENE := preload("res://scenes/world_0.tscn")
const PLANE_CHARACTER_SCENE := preload("res://scenes/plane_character.tscn")
const PLANE_BOT_PILOT_SCRIPT := preload("res://scripts/plane_bot_pilot.gd")
const BOT_DUEL_CAMERA_SCENE := preload("res://scenes/bot_duel_camera.tscn")

@export var spawn_altitude: float = 2500.0
@export var bot_separation: float = 900.0
@export var initial_forward_speed: float = 160.0
@export var bot_default_altitude: float = 2500.0
@export var bot_killzone_distance: float = 250.0
@export var bot_killzone_tolerance: float = 150.0

@onready var _characters: Node3D = $characters


func _ready() -> void:
	_import_level_and_env()

	var bot_a := _spawn_bot("BotA", 1000000, Vector3(-bot_separation * 0.5, spawn_altitude, 0.0))
	var bot_b := _spawn_bot("BotB", 1000001, Vector3(bot_separation * 0.5, spawn_altitude, 0.0))
	_face_plane_at(bot_a, bot_b.global_position)
	_face_plane_at(bot_b, bot_a.global_position)
	_seed_forward_speed(bot_a)
	_seed_forward_speed(bot_b)

	var pilot_a := _attach_bot_pilot(bot_a)
	var pilot_b := _attach_bot_pilot(bot_b)
	pilot_a.call("set_follow_target", bot_b, true)
	pilot_b.call("set_follow_target", bot_a, true)

	_spawn_camera(bot_a, bot_b)


func _import_level_and_env() -> void:
	var world := WORLD_SCENE.instantiate()
	_detach_world_child(world, "level")
	_detach_world_child(world, "env")
	world.free()


func _detach_world_child(world: Node, child_name: String) -> void:
	var child := world.get_node_or_null(NodePath(child_name))
	if child == null:
		push_warning("Bot duel scene could not find world child: %s" % child_name)
		return

	world.remove_child(child)
	_clear_owner_recursive(child)
	add_child(child)


func _clear_owner_recursive(node: Node) -> void:
	node.owner = null
	for child_node in node.get_children():
		_clear_owner_recursive(child_node)


func _spawn_bot(bot_name: String, peer_id: int, spawn_point: Vector3) -> RigidBody3D:
	var plane := PLANE_CHARACTER_SCENE.instantiate() as RigidBody3D
	plane.name = bot_name
	plane.position = spawn_point
	if plane.has_method("configure"):
		plane.call("configure", peer_id, false)
	if plane.has_method("set_bot_controlled"):
		plane.call("set_bot_controlled", true)

	_characters.add_child(plane)
	return plane


func _attach_bot_pilot(plane: RigidBody3D) -> Node:
	var pilot := plane.get_node_or_null("PlaneBotPilot")
	if pilot == null:
		pilot = PLANE_BOT_PILOT_SCRIPT.new()
		pilot.name = "PlaneBotPilot"
		plane.add_child(pilot)

	pilot.set("default_altitude", bot_default_altitude)
	pilot.set("killzone_distance", bot_killzone_distance)
	pilot.set("killzone_tolerance", bot_killzone_tolerance)
	if _has_display_settings():
		pilot.set("debug_bot_visuals_enabled", DisplaySettings.bot_debug_enabled)
	if pilot.has_method("climb_to_altitude"):
		pilot.call("climb_to_altitude", bot_default_altitude)
	return pilot


func _face_plane_at(plane: Node3D, target_point: Vector3) -> void:
	plane.rotation = Vector3(0.0, _yaw_towards(plane.global_position, target_point), 0.0)


func _yaw_towards(from_point: Vector3, to_point: Vector3) -> float:
	var horizontal_offset := Vector3(to_point.x - from_point.x, 0.0, to_point.z - from_point.z)
	if horizontal_offset.length_squared() <= 0.000001:
		return 0.0

	var direction := horizontal_offset.normalized()
	return atan2(-direction.x, -direction.z)


func _seed_forward_speed(plane: RigidBody3D) -> void:
	var forward_axis := -plane.global_transform.basis.z.normalized()
	plane.linear_velocity = forward_axis * maxf(initial_forward_speed, 0.0)
	plane.angular_velocity = Vector3.ZERO


func _spawn_camera(bot_a: Node3D, bot_b: Node3D) -> void:
	var camera_rig := BOT_DUEL_CAMERA_SCENE.instantiate()
	add_child(camera_rig)
	if camera_rig.has_method("set_targets"):
		var targets: Array[Node3D] = [bot_a, bot_b]
		camera_rig.call("set_targets", targets)


func _has_display_settings() -> bool:
	return Engine.has_singleton("DisplaySettings") or get_node_or_null("/root/DisplaySettings") != null
