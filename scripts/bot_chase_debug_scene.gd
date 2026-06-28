extends Node3D

const WORLD_LEVEL_SCENE := preload("res://scenes/world_level.tscn")
const PLANE_CHARACTER_SCENE := preload("res://scenes/plane_character.tscn")
const PLANE_BOT_SETUP := preload("res://scripts/plane_bot_setup.gd")
const BOT_DUEL_CAMERA_SCENE := preload("res://scenes/bot_duel_camera.tscn")
const DISPLAY_SETTINGS_APPLIER := preload("res://scripts/display_settings_applier.gd")
const MIN_DIRECTION_LENGTH_SQUARED := 0.000001
const KILLZONE_MARKER_SEGMENTS := 32

@export var spawn_altitude: float = 2500.0
@export var dummy_speed: float = 120.0
@export var dummy_direction_world := Vector3.FORWARD
@export var bot_start_behind_distance: float = 900.0
@export var bot_start_lateral_offset: float = 350.0
@export var initial_bot_forward_speed: float = 160.0
@export var bot_default_altitude: float = 2500.0
@export var bot_killzone_distance: float = 250.0
@export var bot_killzone_tolerance: float = 150.0
@export var bot_autocannon_fire_max_range: float = 650.0
@export var score_radius: float = 600.0
@export var score_points_per_second: float = 1.0
@export var measurement_sample_interval: float = 0.25

@onready var _characters: Node3D = $characters
@onready var _dummy_target: Node3D = %DummyTarget
@onready var _killzone_marker: Node3D = %KillzoneMarker
@onready var _score_label: Label = %ScoreLabel

var _bot: RigidBody3D
var _target_direction := Vector3.FORWARD
var _score := 0.0
var _score_rate := 0.0
var _elapsed_time := 0.0
var _distance_to_killzone := INF
var _measurement_timer := 0.0
var _measurements: Array[Dictionary] = []
var _current_off_nose_angle_deg := 0.0
var _current_range := 0.0
var _current_aspect_angle_deg := 0.0
var _current_closure := 0.0
var _measurement_stats_text := "Measurements: 0 samples"
var _benchmark_enabled := false
var _benchmark_duration := 0.0
var _benchmark_time_scale := 1.0
var _killzone_mesh := ImmediateMesh.new()
var _killzone_material := StandardMaterial3D.new()
var _killzone_marker_mesh_instance: MeshInstance3D


func _ready() -> void:
	if _has_display_settings():
		DisplaySettings.settings_changed.connect(_on_display_settings_changed)
	_parse_benchmark_args()
	_spawn_level_and_env()
	_setup_killzone_marker()

	_target_direction = _get_safe_horizontal_direction(dummy_direction_world)
	_configure_dummy_target()
	_bot = _spawn_bot(_get_bot_spawn_position())
	_face_plane_at(_bot, _dummy_target.global_position)
	_seed_forward_speed(_bot)

	var pilot := _bot.get_node_or_null("PlaneBotPilot")
	if pilot != null:
		pilot.call("set_follow_target", _dummy_target, true)

	if _has_display_settings():
		DISPLAY_SETTINGS_APPLIER.apply_to_tree(_characters)

	_spawn_camera(_bot, _dummy_target)
	_update_killzone_marker()
	_record_tactical_measurement()
	_update_score_label()


func _physics_process(delta: float) -> void:
	_elapsed_time += delta
	_move_dummy_target(delta)
	_update_killzone_marker()
	_update_tactical_measurements(delta)
	_update_score(delta)
	_update_score_label()
	_update_benchmark()


func _parse_benchmark_args() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--bot-chase-benchmark="):
			_benchmark_duration = maxf(float(argument.get_slice("=", 1)), 0.0)
			_benchmark_enabled = _benchmark_duration > 0.0
		elif argument.begins_with("--bot-chase-time-scale="):
			_benchmark_time_scale = maxf(float(argument.get_slice("=", 1)), 0.001)

	if _benchmark_enabled:
		Engine.time_scale = _benchmark_time_scale
		print("bot_chase_benchmark start duration=%.2f time_scale=%.2f" % [
			_benchmark_duration,
			_benchmark_time_scale,
		])


func _update_benchmark() -> void:
	if not _benchmark_enabled:
		return

	if _elapsed_time < _benchmark_duration:
		return

	_print_benchmark_summary()
	Engine.time_scale = 1.0
	get_tree().quit()


func _print_benchmark_summary() -> void:
	var average_score_rate := 0.0
	if _elapsed_time > 0.001:
		average_score_rate = _score / _elapsed_time

	print("bot_chase_summary elapsed=%.2f score=%.4f avg_score_rate=%.5f killzone_miss_distance=%.3f" % [
		_elapsed_time,
		_score,
		average_score_rate,
		_distance_to_killzone,
	])
	_print_benchmark_metric("off_nose_deg")
	_print_benchmark_metric("range")
	_print_benchmark_metric("aspect_deg")
	_print_benchmark_metric("closure")


func _print_benchmark_metric(key: String) -> void:
	var stats := _get_measurement_stats(key)
	print("bot_chase_metric %s count=%d mean=%.4f median=%.4f p90=%.4f max=%.4f sd=%.4f" % [
		key,
		int(stats.get("count", 0)),
		float(stats.get("mean", 0.0)),
		float(stats.get("median", 0.0)),
		float(stats.get("p90", 0.0)),
		float(stats.get("max", 0.0)),
		float(stats.get("standard_deviation", 0.0)),
	])


func _spawn_level_and_env() -> void:
	add_child(WORLD_LEVEL_SCENE.instantiate())


func _configure_dummy_target() -> void:
	_dummy_target.global_position = Vector3.ZERO + Vector3.UP * spawn_altitude
	_orient_node_forward(_dummy_target, _target_direction)


func _move_dummy_target(delta: float) -> void:
	_dummy_target.global_position += _target_direction * maxf(dummy_speed, 0.0) * delta
	_orient_node_forward(_dummy_target, _target_direction)
	var lockable := _dummy_target.get_node_or_null("LockableTarget") as LockableTarget
	if lockable != null:
		lockable.velocity = _target_direction * maxf(dummy_speed, 0.0)


func _get_bot_spawn_position() -> Vector3:
	var lateral_axis := Vector3.UP.cross(_target_direction)
	if lateral_axis.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		lateral_axis = Vector3.RIGHT
	else:
		lateral_axis = lateral_axis.normalized()

	var behind_offset := -_target_direction * maxf(bot_start_behind_distance, 0.0)
	var lateral_offset := lateral_axis * bot_start_lateral_offset
	return _dummy_target.global_position + behind_offset + lateral_offset


func _spawn_bot(spawn_point: Vector3) -> RigidBody3D:
	var plane := PLANE_CHARACTER_SCENE.instantiate() as RigidBody3D
	plane.name = "ChaseBot"
	plane.position = spawn_point
	if plane.has_method("configure"):
		plane.call("configure", 1000000, false)
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


func _setup_killzone_marker() -> void:
	_killzone_marker_mesh_instance = _killzone_marker.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if _killzone_marker_mesh_instance == null:
		return

	_killzone_marker.top_level = true
	_killzone_marker.global_transform = Transform3D.IDENTITY
	_killzone_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_killzone_material.vertex_color_use_as_albedo = true
	_killzone_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_killzone_material.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
	_killzone_marker_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_killzone_marker_mesh_instance.mesh = _killzone_mesh
	_killzone_marker_mesh_instance.material_override = _killzone_material


func _update_killzone_marker() -> void:
	if _killzone_marker_mesh_instance == null:
		return

	_killzone_marker.global_transform = Transform3D.IDENTITY
	_killzone_mesh.clear_surfaces()
	_killzone_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _killzone_material)
	_append_killzone_sphere(
		_get_killzone_point(),
		maxf(bot_killzone_tolerance, 0.0),
		Color(0.2, 1.0, 0.15, 0.9)
	)
	_killzone_mesh.surface_end()


func _get_killzone_point() -> Vector3:
	return _dummy_target.global_position + _get_target_behind_direction() * maxf(bot_killzone_distance, 0.0)


func _get_target_behind_direction() -> Vector3:
	var behind := _dummy_target.global_transform.basis.z
	if behind.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return Vector3.BACK

	return behind.normalized()


func _append_killzone_sphere(center: Vector3, radius: float, color: Color) -> void:
	var resolved_radius := maxf(radius, 0.0)
	if resolved_radius <= 0.0:
		return

	_append_killzone_ring(center, resolved_radius, Vector3.RIGHT, Vector3.FORWARD, color)
	_append_killzone_ring(center, resolved_radius, Vector3.RIGHT, Vector3.UP, color)
	_append_killzone_ring(center, resolved_radius, Vector3.FORWARD, Vector3.UP, color)


func _append_killzone_ring(center: Vector3, radius: float, axis_a: Vector3, axis_b: Vector3, color: Color) -> void:
	var first := Vector3.ZERO
	var previous := Vector3.ZERO
	for index in range(KILLZONE_MARKER_SEGMENTS):
		var angle := TAU * float(index) / float(KILLZONE_MARKER_SEGMENTS)
		var point := center + (axis_a * cos(angle) + axis_b * sin(angle)) * radius
		if index == 0:
			first = point
		else:
			_append_killzone_line(previous, point, color)
		previous = point

	_append_killzone_line(previous, first, color)


func _append_killzone_line(from_point: Vector3, to_point: Vector3, color: Color) -> void:
	_killzone_mesh.surface_set_color(color)
	_killzone_mesh.surface_add_vertex(from_point)
	_killzone_mesh.surface_add_vertex(to_point)


func _update_score(delta: float) -> void:
	if _bot == null:
		return

	var distance_to_point := _bot.global_position.distance_to(_get_killzone_point())
	_distance_to_killzone = maxf(distance_to_point - maxf(bot_killzone_tolerance, 0.0), 0.0)
	var resolved_score_radius := maxf(score_radius, 1.0)
	var proximity_score := clampf(1.0 - (_distance_to_killzone / resolved_score_radius), 0.0, 1.0)
	_score_rate = proximity_score * maxf(score_points_per_second, 0.0)
	_score += _score_rate * delta


func _update_tactical_measurements(delta: float) -> void:
	_update_current_tactical_measurement()

	var sample_interval := maxf(measurement_sample_interval, 0.001)
	_measurement_timer += delta
	if _measurement_timer < sample_interval:
		return

	_measurement_timer = fmod(_measurement_timer, sample_interval)
	_record_tactical_measurement()


func _update_current_tactical_measurement() -> void:
	var measurement := _make_tactical_measurement()
	if measurement.is_empty():
		return

	_apply_current_tactical_measurement(measurement)


func _record_tactical_measurement() -> void:
	var measurement := _make_tactical_measurement()
	if measurement.is_empty():
		return

	_apply_current_tactical_measurement(measurement)
	_measurements.append(measurement)
	_measurement_stats_text = _build_measurement_stats_text()


func _make_tactical_measurement() -> Dictionary:
	if _bot == null:
		return {}

	var bot_position := _bot.global_position
	var target_position := _dummy_target.global_position
	var target_offset := target_position - bot_position
	var target_range := target_offset.length()
	var line_to_target := _target_direction
	if target_range > 0.001:
		line_to_target = target_offset / target_range

	var bot_forward := -_bot.global_transform.basis.z.normalized()
	var target_forward := -_dummy_target.global_transform.basis.z.normalized()
	var target_to_bot := -line_to_target
	var target_velocity := _target_direction * maxf(dummy_speed, 0.0)

	return {
		"time": _elapsed_time,
		"off_nose_deg": _get_angle_deg(bot_forward, line_to_target),
		"range": target_range,
		"aspect_deg": _get_angle_deg(target_forward, target_to_bot),
		"closure": (_bot.linear_velocity - target_velocity).dot(line_to_target),
	}


func _apply_current_tactical_measurement(measurement: Dictionary) -> void:
	_current_off_nose_angle_deg = float(measurement.get("off_nose_deg", 0.0))
	_current_range = float(measurement.get("range", 0.0))
	_current_aspect_angle_deg = float(measurement.get("aspect_deg", 0.0))
	_current_closure = float(measurement.get("closure", 0.0))


func _build_measurement_stats_text() -> String:
	return "\n".join([
		"Samples: %d" % _measurements.size(),
		_format_measurement_stats("Off-nose", "off_nose_deg", "deg"),
		_format_measurement_stats("Range", "range", "m"),
		_format_measurement_stats("Aspect", "aspect_deg", "deg"),
		_format_measurement_stats("Closure", "closure", "m/s"),
	])


func _format_measurement_stats(label: String, key: String, units: String) -> String:
	var stats := _get_measurement_stats(key)
	if int(stats.get("count", 0)) <= 0:
		return "%s: no samples" % label

	return "%s mean %.1f %s | med %.1f | sd %.1f" % [
		label,
		float(stats["mean"]),
		units,
		float(stats["median"]),
		float(stats["standard_deviation"]),
	]


func _get_measurement_stats(key: String) -> Dictionary:
	if _measurements.is_empty():
		return {
			"count": 0,
			"mean": 0.0,
			"median": 0.0,
			"p90": 0.0,
			"max": 0.0,
			"standard_deviation": 0.0,
		}

	var values: Array[float] = []
	var total := 0.0
	for measurement: Dictionary in _measurements:
		var value := float(measurement.get(key, 0.0))
		values.append(value)
		total += value

	values.sort()
	var count := values.size()
	var mean := total / float(count)
	var median := _get_median(values)
	var p90 := _get_percentile(values, 0.9)
	var max_value := values[count - 1]
	var variance := 0.0
	for value in values:
		var difference := value - mean
		variance += difference * difference

	return {
		"count": count,
		"mean": mean,
		"median": median,
		"p90": p90,
		"max": max_value,
		"standard_deviation": sqrt(variance / float(count)),
	}


func _get_median(sorted_values: Array[float]) -> float:
	if sorted_values.is_empty():
		return 0.0

	var count := sorted_values.size()
	var middle_index := count >> 1
	if count % 2 == 1:
		return sorted_values[middle_index]

	return (sorted_values[middle_index - 1] + sorted_values[middle_index]) * 0.5


func _get_percentile(sorted_values: Array[float], percentile: float) -> float:
	if sorted_values.is_empty():
		return 0.0

	var clamped_percentile := clampf(percentile, 0.0, 1.0)
	var index := roundi(clamped_percentile * float(sorted_values.size() - 1))
	return sorted_values[clampi(index, 0, sorted_values.size() - 1)]


func _update_score_label() -> void:
	var average_score_rate := 0.0
	if _elapsed_time > 0.001:
		average_score_rate = _score / _elapsed_time

	_score_label.text = "\n".join([
		"Bot Chase Debug (main)",
		"Score: %.2f" % _score,
		"Rate: %.2f / s" % _score_rate,
		"Average: %.2f / s" % average_score_rate,
		"Killzone miss: %.1f m" % _distance_to_killzone,
		"Dummy speed: %.1f m/s" % dummy_speed,
		"Current off-nose: %.1f deg" % _current_off_nose_angle_deg,
		"Current range: %.1f m" % _current_range,
		"Current aspect: %.1f deg" % _current_aspect_angle_deg,
		"Current closure: %.1f m/s" % _current_closure,
		_measurement_stats_text,
	])


func _face_plane_at(plane: Node3D, target_point: Vector3) -> void:
	plane.rotation = Vector3(0.0, _yaw_towards(plane.global_position, target_point), 0.0)


func _yaw_towards(from_point: Vector3, to_point: Vector3) -> float:
	var horizontal_offset := Vector3(to_point.x - from_point.x, 0.0, to_point.z - from_point.z)
	if horizontal_offset.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return 0.0

	var direction := horizontal_offset.normalized()
	return atan2(-direction.x, -direction.z)


func _seed_forward_speed(plane: RigidBody3D) -> void:
	var forward_axis := -plane.global_transform.basis.z.normalized()
	plane.linear_velocity = forward_axis * maxf(initial_bot_forward_speed, 0.0)
	plane.angular_velocity = Vector3.ZERO


func _spawn_camera(bot: Node3D, target: Node3D) -> void:
	var camera_rig := BOT_DUEL_CAMERA_SCENE.instantiate()
	add_child(camera_rig)
	if camera_rig.has_method("set_targets"):
		var targets: Array[Node3D] = [bot, target]
		camera_rig.call("set_targets", targets)


func _orient_node_forward(node: Node3D, forward_direction: Vector3) -> void:
	if forward_direction.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return

	node.look_at(node.global_position + forward_direction.normalized(), Vector3.UP)


func _get_safe_horizontal_direction(direction: Vector3) -> Vector3:
	var horizontal_direction := Vector3(direction.x, 0.0, direction.z)
	if horizontal_direction.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return Vector3.FORWARD

	return horizontal_direction.normalized()


func _get_angle_deg(first_direction: Vector3, second_direction: Vector3) -> float:
	if first_direction.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return 0.0
	if second_direction.length_squared() <= MIN_DIRECTION_LENGTH_SQUARED:
		return 0.0

	var alignment := first_direction.normalized().dot(second_direction.normalized())
	return rad_to_deg(acos(clampf(alignment, -1.0, 1.0)))


func _on_display_settings_changed() -> void:
	DISPLAY_SETTINGS_APPLIER.apply_to_tree(_characters)


func _has_display_settings() -> bool:
	return Engine.has_singleton("DisplaySettings") or get_node_or_null("/root/DisplaySettings") != null
