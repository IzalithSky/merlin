extends Node3D

const WORLD_LEVEL_SCENE := preload("res://scenes/world_level.tscn")
const PLANE_CHARACTER_SCENE := preload("res://scenes/plane_character.tscn")
const PLANE_BOT_SETUP := preload("res://scripts/plane_bot_setup.gd")
const BOT_DUEL_CAMERA_SCENE := preload("res://scenes/bot_duel_camera.tscn")
const DISPLAY_SETTINGS_APPLIER := preload("res://scripts/display_settings_applier.gd")

@export var spawn_altitude: float = 500.0
@export var bot_separation: float = 1500.0
@export var initial_forward_speed: float = 160.0
@export var bot_default_altitude: float = 2500.0
@export var bot_killzone_distance: float = 250.0
@export var bot_killzone_tolerance: float = 150.0
@export var bot_autocannon_fire_max_range: float = 650.0

@onready var _characters: Node3D = $characters


func _ready() -> void:
	if _has_display_settings():
		DisplaySettings.settings_changed.connect(_on_display_settings_changed)
	_spawn_level_and_env()

	var bot_a := _spawn_bot("BotA", 1000000, Vector3(-bot_separation * 0.5, spawn_altitude, 0.0))
	var bot_b := _spawn_bot("BotB", 1000001, Vector3(bot_separation * 0.5, spawn_altitude, 0.0))
	_face_plane_in_direction(bot_a, Vector3.FORWARD)
	_face_plane_in_direction(bot_b, Vector3.FORWARD)
	_seed_forward_speed(bot_a)
	_seed_forward_speed(bot_b)

	var pilot_a := bot_a.get_node_or_null("PlaneBotPilot")
	var pilot_b := bot_b.get_node_or_null("PlaneBotPilot")
	if pilot_a != null:
		pilot_a.call("set_follow_target", bot_b, true)
	if pilot_b != null:
		pilot_b.call("set_follow_target", bot_a, true)

	if _has_display_settings():
		DISPLAY_SETTINGS_APPLIER.apply_to_tree(_characters)

	_spawn_camera(bot_a, bot_b)


func _spawn_level_and_env() -> void:
	add_child(WORLD_LEVEL_SCENE.instantiate())


func _spawn_bot(bot_name: String, peer_id: int, spawn_point: Vector3) -> RigidBody3D:
	var plane := PLANE_CHARACTER_SCENE.instantiate() as RigidBody3D
	plane.name = bot_name
	plane.position = spawn_point
	if plane.has_method("configure"):
		plane.call("configure", peer_id, false)
	_configure_bot_pilot(plane)
	_characters.add_child(plane)
	return plane


func _configure_bot_pilot(plane: RigidBody3D) -> Node:
	return PLANE_BOT_SETUP.configure_plane(
		plane,
		true,
		true,
		bot_killzone_distance,
		bot_killzone_tolerance,
		bot_default_altitude,
		bot_autocannon_fire_max_range,
		DisplaySettings.bot_debug_enabled if _has_display_settings() else true,
		0
	)


func _face_plane_at(plane: Node3D, target_point: Vector3) -> void:
	plane.rotation = Vector3(0.0, _yaw_towards(plane.global_position, target_point), 0.0)


func _face_plane_in_direction(plane: Node3D, direction_world: Vector3) -> void:
	if direction_world.length_squared() <= 0.000001:
		return
	plane.rotation = Vector3(0.0, _yaw_towards(Vector3.ZERO, direction_world.normalized()), 0.0)


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


func _on_display_settings_changed() -> void:
	DISPLAY_SETTINGS_APPLIER.apply_to_tree(_characters)


func _has_display_settings() -> bool:
	return Engine.has_singleton("DisplaySettings") or get_node_or_null("/root/DisplaySettings") != null
