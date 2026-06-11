extends CanvasLayer

const NOSE_DIRECTION_TEXTURE_PATH := "res://textures/hud/nose_sprite.png"
const VELOCITY_DIRECTION_TEXTURE_PATH := "res://textures/hud/heading_sprite.png"

@onready var _airspeed_value: Label = %AirspeedValue
@onready var _vertical_speed_value: Label = %VerticalSpeedValue
@onready var _altitude_value: Label = %AltitudeValue
@onready var _throttle_value: Label = %ThrottleValue
@onready var _aoa_value: Label = %AoaValue
@onready var _pitch_input_bar: ProgressBar = %PitchInputBar
@onready var _yaw_input_bar: ProgressBar = %YawInputBar
@onready var _roll_input_bar: ProgressBar = %RollInputBar
@onready var _throttle_input_bar: ProgressBar = %ThrottleInputBar
@onready var _force_axis_speed_value: Label = %ForceAxisSpeedValue
@onready var _thrust_along_value: Label = %ThrustAlongValue
@onready var _drag_along_value: Label = %DragAlongValue
@onready var _gravity_along_value: Label = %GravityAlongValue
@onready var _damping_along_value: Label = %DampingAlongValue
@onready var _net_along_value: Label = %NetAlongValue
@onready var _relative_roll_clock: Control = %RelativeRollClock
@onready var _vy_speed_value: Label = %VySpeedValue
@onready var _vy_active_value: Label = %VyActiveValue
@onready var _hp_value: Label = %HpValue
@onready var _nose_direction_indicator: TextureRect = %NoseDirectionIndicator
@onready var _velocity_direction_indicator: TextureRect = %VelocityDirectionIndicator

var _target: RigidBody3D
var _camera: Camera3D
var _advanced_hud_nodes: Array[CanvasItem] = []
var _advanced_hud_enabled := true
var _relative_roll_clock_enabled := true
var _global_direction_markers_enabled := true
var _base_root_size := Vector2.ZERO
var _indicator_half_size := Vector2.ZERO

const GLOBAL_DIRECTION_MARKER_DISTANCE := 1000.0
const MIN_DIRECTION_SPEED_SQUARED := 0.01


func _ready() -> void:
	_base_root_size = $Root.size
	_indicator_half_size = _nose_direction_indicator.size * 0.5
	_assign_global_direction_indicator_textures()
	_collect_advanced_hud_nodes()
	DisplaySettings.settings_changed.connect(_apply_display_settings)
	_apply_display_settings()
	_reset_labels()
	_reset_global_direction_indicators()


func set_target(target: Node3D = null) -> void:
	_target = target as RigidBody3D
	if _target == null:
		_reset_labels()
		_reset_global_direction_indicators()


func set_camera(cam: Camera3D) -> void:
	_camera = cam


func _process(_delta: float) -> void:
	if _target == null:
		_reset_global_direction_indicators()
		return

	if not is_instance_valid(_target):
		_target = null
		_reset_labels()
		_reset_global_direction_indicators()
		return

	var forward_axis := -_target.global_transform.basis.z
	var airspeed_forward := _target.linear_velocity.dot(forward_axis)
	var vertical_speed := _target.linear_velocity.y
	var altitude := _target.global_position.y
	var throttle_percent := 0.0
	var aoa_deg := 0.0
	var pitch_input := 0.0
	var yaw_input := 0.0
	var roll_input := 0.0
	var throttle_input := -1.0

	if _target.has_method("get_throttle_percent"):
		throttle_percent = float(_target.call("get_throttle_percent"))
	if _target.has_method("get_aoa_deg"):
		aoa_deg = float(_target.call("get_aoa_deg"))
	if _target.has_method("get_pitch_input"):
		pitch_input = float(_target.call("get_pitch_input"))
	if _target.has_method("get_yaw_input"):
		yaw_input = float(_target.call("get_yaw_input"))
	if _target.has_method("get_roll_input"):
		roll_input = float(_target.call("get_roll_input"))
	if _target.has_method("get_throttle_input"):
		throttle_input = float(_target.call("get_throttle_input"))

	_airspeed_value.text = "%.1f m/s" % airspeed_forward
	_vertical_speed_value.text = "%.1f m/s" % vertical_speed
	_altitude_value.text = "%.1f m" % altitude
	_throttle_value.text = "%.0f %%" % throttle_percent

	var health := _target.get_node_or_null("Health")
	if health != null:
		var max_hp: float = float(health.get("max_hp"))
		var current_hp: float = float(health.get("current_hp"))
		_hp_value.text = "%d / %d" % [int(current_hp), int(max_hp)]
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
		_update_force_balance_debug()
		_update_vy_debug()

	_update_relative_roll_clock()
	_update_global_direction_indicators()


func _reset_labels() -> void:
	_airspeed_value.text = "--"
	_vertical_speed_value.text = "--"
	_altitude_value.text = "--"
	_throttle_value.text = "--"
	_hp_value.text = "--"
	_aoa_value.text = "--"
	_pitch_input_bar.value = 0.0
	_yaw_input_bar.value = 0.0
	_roll_input_bar.value = 0.0
	_throttle_input_bar.value = -100.0
	_reset_force_balance_debug()


func _reset_advanced_labels() -> void:
	_aoa_value.text = "--"
	_pitch_input_bar.value = 0.0
	_yaw_input_bar.value = 0.0
	_roll_input_bar.value = 0.0
	_throttle_input_bar.value = -100.0
	_force_axis_speed_value.text = "--"
	_thrust_along_value.text = "--"
	_drag_along_value.text = "--"
	_gravity_along_value.text = "--"
	_damping_along_value.text = "--"
	_net_along_value.text = "--"
	_vy_speed_value.text = "--"
	_vy_active_value.text = "--"


func _update_force_balance_debug() -> void:
	if _target == null or not _target.has_method("get_force_balance_snapshot"):
		_reset_force_balance_debug()
		return

	var snapshot_variant: Variant = _target.call("get_force_balance_snapshot")
	if not (snapshot_variant is Dictionary):
		_reset_force_balance_debug()
		return

	var snapshot: Dictionary = snapshot_variant
	_force_axis_speed_value.text = "%.1f m/s" % _read_snapshot_float(snapshot, "speed")
	_thrust_along_value.text = "%.1f N" % _read_snapshot_float(snapshot, "thrust_along_velocity")
	_drag_along_value.text = "%.1f N" % _read_snapshot_float(snapshot, "drag_along_velocity")
	_gravity_along_value.text = "%.1f N" % _read_snapshot_float(snapshot, "gravity_along_velocity")
	_damping_along_value.text = "%.1f N" % _read_snapshot_float(snapshot, "damping_along_velocity")
	_net_along_value.text = "%.1f N" % _read_snapshot_float(snapshot, "net_along_velocity")


func _update_vy_debug() -> void:
	if _target == null or not _target.has_method("get_best_climb_speed_vy"):
		_vy_speed_value.text = "--"
		_vy_active_value.text = "--"
		return

	var vy := float(_target.call("get_best_climb_speed_vy"))
	var valid := bool(_target.call("is_best_climb_speed_vy_valid"))
	var using_vy := bool(_target.call("is_sustain_turn_using_vy"))
	_vy_speed_value.text = ("%.1f m/s" % vy) if valid else "---"
	_vy_active_value.text = "YES" if using_vy else "no"


func _update_relative_roll_clock() -> void:
	if _relative_roll_clock == null:
		return

	if not _relative_roll_clock_enabled:
		_relative_roll_clock.visible = false
		return

	if _target == null or not _target.has_method("is_relative_roll_active"):
		_relative_roll_clock.visible = false
		return

	var is_active := bool(_target.call("is_relative_roll_active"))
	_relative_roll_clock.visible = is_active
	if _target.has_method("get_relative_roll_error"):
		_relative_roll_clock.set("roll_error", float(_target.call("get_relative_roll_error")))


func _reset_force_balance_debug() -> void:
	_force_axis_speed_value.text = "--"
	_thrust_along_value.text = "--"
	_drag_along_value.text = "--"
	_gravity_along_value.text = "--"
	_damping_along_value.text = "--"
	_net_along_value.text = "--"


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


func _update_global_direction_indicators() -> void:
	if _camera == null or not is_instance_valid(_camera) or _target == null:
		_reset_global_direction_indicators()
		return

	if not _global_direction_markers_enabled:
		_reset_global_direction_indicators()
		return

	var nose_direction := -_target.global_transform.basis.z
	_update_global_direction_indicator(_nose_direction_indicator, nose_direction)

	var velocity := _target.linear_velocity
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


func _read_snapshot_float(snapshot: Dictionary, key: String) -> float:
	return float(snapshot.get(key, 0.0))


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
		"ForceSectionLabel",
		"ForceSectionValueSpacer",
		"ForceAxisSpeedLabel",
		"ForceAxisSpeedValue",
		"ThrustAlongLabel",
		"ThrustAlongValue",
		"DragAlongLabel",
		"DragAlongValue",
		"GravityAlongLabel",
		"GravityAlongValue",
		"DampingAlongLabel",
		"DampingAlongValue",
		"NetAlongLabel",
		"NetAlongValue",
		"VySectionLabel",
		"VySectionValueSpacer",
		"VySpeedLabel",
		"VySpeedValue",
		"VyActiveLabel",
		"VyActiveValue",
	]

	for node_name in node_names:
		var hud_node := grid.get_node_or_null(node_name) as CanvasItem
		if hud_node != null:
			_advanced_hud_nodes.append(hud_node)


func _apply_display_settings() -> void:
	_advanced_hud_enabled = DisplaySettings.advanced_hud_enabled
	_relative_roll_clock_enabled = DisplaySettings.relative_roll_clock_enabled
	_global_direction_markers_enabled = DisplaySettings.global_direction_markers_enabled
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
