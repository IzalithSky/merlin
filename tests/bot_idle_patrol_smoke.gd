extends Node3D

const PLANE_SCENE := preload("res://scenes/plane_character.tscn")
const BOT_PILOT_SCRIPT := preload("res://scripts/plane_bot_pilot.gd")
const MISSION_CONTROLLER_SCRIPT := preload("res://scripts/mission_controller.gd")

const AREA_MIN := Vector3(-1000.0, 500.0, -1000.0)
const AREA_MAX := Vector3(1000.0, 1500.0, 1000.0)
const HORIZONTAL_SEPARATION := 500.0
const ALTITUDE_SEPARATION := 200.0


func _ready() -> void:
	await _assert_default_fallback_patrol()

	var controller := MISSION_CONTROLLER_SCRIPT.new()
	controller.name = "MissionController"
	add_child(controller)
	controller.load_mission({
		"areas": {
			"patrol": {"min": AREA_MIN, "max": AREA_MAX},
			"other": {
				"min": Vector3(5000.0, 500.0, 5000.0),
				"max": Vector3(6000.0, 1500.0, 6000.0),
			},
		},
		"default_mob_area": "patrol",
	})

	var bounds: Dictionary = controller.get_control_area_bounds("patrol")
	_assert(bounds.get("min") == AREA_MIN, "expected explicit patrol area minimum")
	_assert(bounds.get("max") == AREA_MAX, "expected explicit patrol area maximum")

	var bot_plane := PLANE_SCENE.instantiate() as RigidBody3D
	bot_plane.name = "BotPlane"
	bot_plane.position = Vector3(0.0, 1000.0, 0.0)
	add_child(bot_plane)
	bot_plane.configure(1000000, false)
	bot_plane.set_bot_controlled(true)
	bot_plane.linear_velocity = Vector3(0.0, 0.0, -100.0)

	var pilot := BOT_PILOT_SCRIPT.new()
	pilot.name = "PlaneBotPilot"
	pilot.idle_checkpoint_interval_sec = 0.3
	pilot.idle_checkpoint_horizontal_separation = HORIZONTAL_SEPARATION
	pilot.idle_checkpoint_altitude_separation = ALTITUDE_SEPARATION
	bot_plane.add_child(pilot)
	pilot.set_idle_checkpoint_random_seed(12345)

	await get_tree().create_timer(0.05).timeout
	var first_checkpoint: Vector3 = pilot.get_idle_checkpoint()
	_assert(_is_inside_area(first_checkpoint), "first checkpoint must stay inside patrol area")
	_assert(is_equal_approx(float(pilot.get("_throttle_input")), 1.0), "idle bot must command full throttle")
	_assert(_get_debug_label_text(pilot).contains("CHK ("), "debug label must include active checkpoint")

	bot_plane.linear_velocity = Vector3(0.0, 0.0, -200.0)
	await get_tree().create_timer(0.05).timeout
	_assert(pilot.get_flight_state_name() == "SPEED_REDUCTION", "idle overspeed must override checkpoint pursuit")
	_assert(float(pilot.get("_throttle_input")) < 1.0, "idle overspeed must reduce throttle")
	bot_plane.linear_velocity = Vector3(0.0, 0.0, -20.0)
	await get_tree().create_timer(0.05).timeout
	_assert(pilot.get_flight_state_name() == "SPEED_RECOVERY", "idle low speed must override checkpoint pursuit")
	_assert(is_equal_approx(float(pilot.get("_throttle_input")), 1.0), "idle speed recovery must command full throttle")
	bot_plane.linear_velocity = Vector3(0.0, 0.0, -100.0)

	await get_tree().create_timer(0.25).timeout
	var second_checkpoint: Vector3 = pilot.get_idle_checkpoint()
	_assert(second_checkpoint != first_checkpoint, "checkpoint must refresh after configured interval")
	_assert(_is_inside_area(second_checkpoint), "second checkpoint must stay inside patrol area")
	var horizontal_distance := Vector2(
		second_checkpoint.x - first_checkpoint.x,
		second_checkpoint.z - first_checkpoint.z
	).length()
	_assert(horizontal_distance >= HORIZONTAL_SEPARATION, "checkpoint horizontal separation is too small")
	_assert(
		absf(second_checkpoint.y - first_checkpoint.y) >= ALTITUDE_SEPARATION,
		"checkpoint altitude separation is too small"
	)
	bot_plane.global_position = second_checkpoint
	await get_tree().create_timer(0.05).timeout
	_assert(pilot.get_idle_checkpoint() != second_checkpoint, "checkpoint must advance inside reach tolerance")

	print("bot_idle_patrol_smoke_ok first=%s second=%s" % [first_checkpoint, second_checkpoint])
	get_tree().quit(0)


func _assert_default_fallback_patrol() -> void:
	var terrain := StaticBody3D.new()
	terrain.name = "TestTerrain"
	terrain.position = Vector3(0.0, 900.0, 0.0)
	terrain.add_to_group("terrain")
	var terrain_shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(10000.0, 100.0, 10000.0)
	terrain_shape.shape = box_shape
	terrain.add_child(terrain_shape)
	add_child(terrain)

	var bot_plane := PLANE_SCENE.instantiate() as RigidBody3D
	bot_plane.name = "FallbackBotPlane"
	bot_plane.position = Vector3(0.0, 1000.0, 0.0)
	add_child(bot_plane)
	bot_plane.configure(1000001, false)
	bot_plane.set_bot_controlled(true)
	bot_plane.linear_velocity = Vector3(0.0, 0.0, -100.0)

	var pilot := BOT_PILOT_SCRIPT.new()
	pilot.name = "PlaneBotPilot"
	pilot.debug_bot_visuals_enabled = false
	bot_plane.add_child(pilot)
	await get_tree().create_timer(0.05).timeout

	var checkpoint: Vector3 = pilot.get_idle_checkpoint()
	_assert(bool(pilot.get("_idle_checkpoint_active")), "fallback checkpoint must be active without mission controller")
	_assert(
		checkpoint.x >= -3000.0 and checkpoint.x <= 3000.0
			and checkpoint.y >= 1750.0 and checkpoint.y <= 2500.0
			and checkpoint.z >= -3000.0 and checkpoint.z <= 3000.0,
		"fallback checkpoint must stay inside patrol box and above terrain clearance"
	)

	var terrain_wall := StaticBody3D.new()
	terrain_wall.name = "TestTerrainWall"
	terrain_wall.position = Vector3(0.0, 1600.0, -500.0)
	terrain_wall.add_to_group("terrain")
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(500.0, 1000.0, 100.0)
	wall_shape.shape = wall_box
	terrain_wall.add_child(wall_shape)
	add_child(terrain_wall)
	await get_tree().physics_frame
	_assert(
		not bool(pilot.call(
			"_is_idle_checkpoint_path_clear",
			Vector3(0.0, 1600.0, 0.0),
			Vector3(0.0, 1600.0, -1000.0)
		)),
		"terrain wall must occlude checkpoint route"
	)
	bot_plane.queue_free()
	terrain.queue_free()
	terrain_wall.queue_free()
	await get_tree().physics_frame


func _is_inside_area(point: Vector3) -> bool:
	return point.x >= AREA_MIN.x and point.x <= AREA_MAX.x \
		and point.y >= AREA_MIN.y and point.y <= AREA_MAX.y \
		and point.z >= AREA_MIN.z and point.z <= AREA_MAX.z


func _get_debug_label_text(pilot: Node) -> String:
	var renderer := pilot.get_node_or_null("BotDebugRenderer3D")
	if renderer == null:
		return ""
	for child in renderer.get_children():
		if child is Label3D:
			return (child as Label3D).text
	return ""


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	get_tree().quit(1)
