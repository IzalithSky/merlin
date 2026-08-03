class_name PlaneTelemetryHud
extends CanvasLayer

const NOSE_DIRECTION_TEXTURE_PATH := "res://textures/hud/nose_sprite.png"
const VELOCITY_DIRECTION_TEXTURE_PATH := "res://textures/hud/heading_sprite.png"

@onready var _airspeed_value: Label = %AirspeedValue
@onready var _vertical_speed_value: Label = %VerticalSpeedValue
@onready var _altitude_value: Label = %AltitudeValue
@onready var _throttle_value: Label = %ThrottleValue
@onready var _aoa_value: Label = %AoaValue
@onready var _pitch_assist_value: Label = %PitchAssistValue
@onready var _stabilization_assist_value: Label = %StabilizationAssistValue
@onready var _input_decay_value: Label = %InputDecayValue
@onready var _sustain_turn_value: Label = %SustainTurnValue
@onready var _pitch_input_bar: ProgressBar = %PitchInputBar
@onready var _yaw_input_bar: ProgressBar = %YawInputBar
@onready var _roll_input_bar: ProgressBar = %RollInputBar
@onready var _throttle_input_bar: ProgressBar = %ThrottleInputBar
@onready var _relative_roll_clock: Control = %RelativeRollClock
@onready var _hp_value: Label = %HpValue
@onready var _nose_direction_indicator: TextureRect = %NoseDirectionIndicator
@onready var _velocity_direction_indicator: TextureRect = %VelocityDirectionIndicator
@onready var _fps_label: Label = %FpsLabel
@onready var _frame_time_label: Label = %FrameTimeLabel
@onready var _position_label: Label = %PositionLabel
@onready var _origin_distance_label: Label = %OriginDistanceLabel

var _target
var _camera: Camera3D
var _advanced_hud_nodes: Array[CanvasItem] = []
var _advanced_hud_enabled := true
var _relative_roll_clock_enabled := true
var _global_direction_markers_enabled := true
var _shot_down_detached := false
var _base_root_size := Vector2.ZERO
var _indicator_half_size := Vector2.ZERO
var _net_metrics_label: Label

const GLOBAL_DIRECTION_MARKER_DISTANCE := 1000.0
const MIN_DIRECTION_SPEED_SQUARED := 0.01


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_base_root_size = $Root.size
	_indicator_half_size = _nose_direction_indicator.size * 0.5
	_create_net_metrics_label()
	_assign_global_direction_indicator_textures()
	_collect_advanced_hud_nodes()
	var display_settings := get_node_or_null("/root/DisplaySettings")
	if display_settings != null:
		display_settings.settings_changed.connect(_apply_display_settings)
	_apply_display_settings()
	_reset_labels()
	_reset_global_direction_indicators()


func set_target(target: Node3D = null) -> void:
	_target = target
	if _target == null:
		_reset_labels()
		_reset_global_direction_indicators()
	else:
		_shot_down_detached = false


func set_camera(cam: Camera3D) -> void:
	_camera = cam


func _process(_delta: float) -> void:
	_fps_label.text = "%d FPS" % Engine.get_frames_per_second()
	var cpu_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var viewport_rid := get_viewport().get_viewport_rid()
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
	if gpu_ms > 0.0:
		_frame_time_label.text = "CPU %.1f ms / GPU %.1f ms" % [cpu_ms, gpu_ms]
	else:
		_frame_time_label.text = "CPU %.1f ms" % cpu_ms

	if _target == null:
		_reset_global_direction_indicators()
		return

	if not is_instance_valid(_target):
		_target = null
		_reset_labels()
		_reset_global_direction_indicators()
		return

	var forward_axis: Vector3 = -_target.global_transform.basis.z
	var airspeed_forward: float = _target.linear_velocity.dot(forward_axis)
	var vertical_speed: float = _target.linear_velocity.y
	var altitude: float = _target.global_position.y
	var throttle_percent := 0.0
	var aoa_deg := 0.0
	var pitch_input := 0.0
	var yaw_input := 0.0
	var roll_input := 0.0
	var throttle_input := -1.0
	var pitch_assist_enabled := true
	var stabilization_assist_enabled := true
	var input_decay_enabled := true
	var sustain_turn_enabled := false

	throttle_percent = _target.get_throttle_percent()
	aoa_deg = _target.get_aoa_deg()
	pitch_input = _target.get_pitch_input()
	yaw_input = _target.get_yaw_input()
	roll_input = _target.get_roll_input()
	throttle_input = _target.get_throttle_input()
	pitch_assist_enabled = _target.is_pitch_assist_enabled()
	stabilization_assist_enabled = _target.is_stabilization_assist_enabled()
	input_decay_enabled = _target.is_input_decay_enabled()
	sustain_turn_enabled = _target.is_sustain_turn_limiter_active()

	_airspeed_value.text = "%.1f m/s" % airspeed_forward
	_vertical_speed_value.text = "%.1f m/s" % vertical_speed
	_altitude_value.text = "%.1f m" % altitude
	var global_pos: Vector3 = _target.global_position
	_position_label.text = "XYZ %d, %d, %d" % [roundi(global_pos.x), roundi(global_pos.y), roundi(global_pos.z)]
	_origin_distance_label.text = "Dist %d m" % roundi(global_pos.length())
	_throttle_value.text = "%.0f %%" % throttle_percent
	_pitch_assist_value.text = "ON" if pitch_assist_enabled else "OFF"
	_stabilization_assist_value.text = "ON" if stabilization_assist_enabled else "OFF"
	_input_decay_value.text = "ON" if input_decay_enabled else "OFF"
	_sustain_turn_value.text = "ON" if sustain_turn_enabled else "OFF"

	var health = _target.get_health_component()
	if health != null:
		_hp_value.text = "%d / %d" % [int(health.current_hp), int(health.max_hp)]
	else:
		_hp_value.text = "--"

	if not _advanced_hud_enabled:
		_reset_advanced_labels()
	else:
		_aoa_value.text = "%.1f deg" % aoa_deg
		_pitch_input_bar.value = pitch_input * 100.0
		_yaw_input_bar.value = yaw_input * 100.0
		_roll_input_bar.value = roll_input * 100.0
		_throttle_input_bar.value = throttle_input * 100.0

	_update_relative_roll_clock()
	_update_global_direction_indicators()
	_update_net_metrics_overlay()


func _reset_labels() -> void:
	_airspeed_value.text = "--"
	_vertical_speed_value.text = "--"
	_altitude_value.text = "--"
	_position_label.text = "XYZ --"
	_origin_distance_label.text = "Dist --"
	_throttle_value.text = "--"
	_hp_value.text = "--"
	_aoa_value.text = "--"
	_pitch_assist_value.text = "--"
	_stabilization_assist_value.text = "--"
	_input_decay_value.text = "--"
	_sustain_turn_value.text = "--"
	_pitch_input_bar.value = 0.0
	_yaw_input_bar.value = 0.0
	_roll_input_bar.value = 0.0
	_throttle_input_bar.value = -100.0
	_update_net_metrics_overlay()


func _reset_advanced_labels() -> void:
	_aoa_value.text = "--"
	_pitch_input_bar.value = 0.0
	_yaw_input_bar.value = 0.0
	_roll_input_bar.value = 0.0
	_throttle_input_bar.value = -100.0


func _update_relative_roll_clock() -> void:
	if _relative_roll_clock == null:
		return

	if not _relative_roll_clock_enabled:
		_relative_roll_clock.visible = false
		return

	if _target == null:
		_relative_roll_clock.visible = false
		return

	var is_active: bool = _target.is_relative_roll_active()
	_relative_roll_clock.visible = is_active
	_relative_roll_clock.set("roll_error", _target.get_relative_roll_error())


func _assign_global_direction_indicator_textures() -> void:
	_assign_indicator_texture(_nose_direction_indicator, NOSE_DIRECTION_TEXTURE_PATH)
	_assign_indicator_texture(_velocity_direction_indicator, VELOCITY_DIRECTION_TEXTURE_PATH)


func _assign_indicator_texture(indicator: TextureRect, resource_path: String) -> void:
	if indicator == null:
		return

	var image := Image.load_from_file(ProjectSettings.globalize_path(resource_path))
	if image == null or image.is_empty():
		return

	indicator.texture = ImageTexture.create_from_image(image)


func _reset_global_direction_indicators() -> void:
	if _nose_direction_indicator != null:
		_nose_direction_indicator.visible = false
	if _velocity_direction_indicator != null:
		_velocity_direction_indicator.visible = false


func on_camera_rig_detached() -> void:
	_shot_down_detached = true
	_reset_global_direction_indicators()


func _update_global_direction_indicators() -> void:
	if _camera == null or not is_instance_valid(_camera) or _target == null:
		_reset_global_direction_indicators()
		return

	if not _global_direction_markers_enabled or _shot_down_detached:
		_reset_global_direction_indicators()
		return

	var nose_direction: Vector3 = -_target.global_transform.basis.z
	_update_global_direction_indicator(_nose_direction_indicator, nose_direction)

	var velocity: Vector3 = _target.linear_velocity
	if velocity.length_squared() <= MIN_DIRECTION_SPEED_SQUARED:
		_velocity_direction_indicator.visible = false
	else:
		_update_global_direction_indicator(_velocity_direction_indicator, velocity)


func _update_global_direction_indicator(indicator: TextureRect, direction_world: Vector3) -> void:
	if indicator == null:
		return

	var direction_length_squared := direction_world.length_squared()
	if direction_length_squared <= 0.000001:
		indicator.visible = false
		return

	var marker_world_position := _camera.global_position + direction_world.normalized() * GLOBAL_DIRECTION_MARKER_DISTANCE
	if _camera.is_position_behind(marker_world_position):
		indicator.visible = false
		return

	var screen_position := _camera.unproject_position(marker_world_position)
	indicator.position = screen_position - _indicator_half_size
	indicator.visible = true


func _collect_advanced_hud_nodes() -> void:
	var grid := get_node("Root/Panel/Margin/Grid")
	var node_names: Array[String] = [
		"AoaLabel",
		"AoaValue",
		"PitchInputLabel",
		"PitchInputBar",
		"YawInputLabel",
		"YawInputBar",
		"RollInputLabel",
		"RollInputBar",
		"ThrottleInputLabel",
		"ThrottleInputBar",
	]

	for node_name in node_names:
		var hud_node := grid.get_node_or_null(node_name) as CanvasItem
		if hud_node != null:
			_advanced_hud_nodes.append(hud_node)


func _apply_display_settings() -> void:
	var display_settings := get_node_or_null("/root/DisplaySettings")
	_advanced_hud_enabled = bool(display_settings.get("advanced_hud_enabled")) if display_settings != null else true
	_relative_roll_clock_enabled = bool(display_settings.get("relative_roll_clock_enabled")) if display_settings != null else true
	_global_direction_markers_enabled = bool(display_settings.get("global_direction_markers_enabled")) if display_settings != null else true
	for hud_node in _advanced_hud_nodes:
		hud_node.visible = _advanced_hud_enabled

	if not _advanced_hud_enabled:
		_reset_advanced_labels()

	if not _relative_roll_clock_enabled and _relative_roll_clock != null:
		_relative_roll_clock.visible = false
	if not _global_direction_markers_enabled:
		_reset_global_direction_indicators()

	call_deferred("_fit_to_contents")


func _fit_to_contents() -> void:
	var panel := $Root/Panel as PanelContainer
	var root := $Root as Control
	panel.reset_size()
	var panel_size := panel.get_combined_minimum_size()
	panel.size = panel_size
	root.size = Vector2(
		maxf(_base_root_size.x, panel.position.x + panel_size.x),
		maxf(_base_root_size.y, panel.position.y + panel_size.y)
	)
	if _net_metrics_label != null:
		_net_metrics_label.position = Vector2(panel.position.x, panel.position.y + panel_size.y + 8.0)


func _create_net_metrics_label() -> void:
	_net_metrics_label = Label.new()
	_net_metrics_label.name = "NetMetricsLabel"
	_net_metrics_label.visible = false
	_net_metrics_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	$Root.add_child(_net_metrics_label)


func _update_net_metrics_overlay() -> void:
	if _net_metrics_label == null:
		return

	var spawner = _find_world_spawner()
	if (
		spawner == null
		or not is_instance_valid(spawner)
		or not _advanced_hud_enabled
		or not spawner.net_metrics_enabled
	):
		_net_metrics_label.visible = false
		return

	var summary_text: String = spawner.get_net_metrics_summary_text()
	if summary_text.is_empty():
		_net_metrics_label.visible = false
		return

	_net_metrics_label.text = "NET %s" % summary_text
	_net_metrics_label.visible = true


func _find_world_spawner():
	if _target != null and is_instance_valid(_target):
		var spawner = WorldCharacterSpawner.find_in_tree(_target)
		if spawner != null:
			return spawner

	var nodes := get_tree().get_nodes_in_group("world_character_spawner")
	if nodes.is_empty():
		return null
	return nodes[0]
