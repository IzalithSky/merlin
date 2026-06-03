extends CanvasLayer

@onready var _airspeed_value: Label = %AirspeedValue
@onready var _vertical_speed_value: Label = %VerticalSpeedValue
@onready var _altitude_value: Label = %AltitudeValue
@onready var _throttle_value: Label = %ThrottleValue
@onready var _aoa_value: Label = %AoaValue
@onready var _aoa_limiter_value: Label = %AoaLimiterValue
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

var _target: RigidBody3D


func _ready() -> void:
	_reset_labels()


func set_target(target: Node3D = null) -> void:
	_target = target as RigidBody3D
	if _target == null:
		_reset_labels()


func _process(_delta: float) -> void:
	if _target == null:
		return

	if not is_instance_valid(_target):
		_target = null
		_reset_labels()
		return

	var forward_axis := -_target.global_transform.basis.z
	var airspeed_forward := _target.linear_velocity.dot(forward_axis)
	var vertical_speed := _target.linear_velocity.y
	var altitude := _target.global_position.y
	var throttle_percent := 0.0
	var aoa_deg := 0.0
	var aoa_limiter_text := "--"
	var pitch_input := 0.0
	var yaw_input := 0.0
	var roll_input := 0.0
	var throttle_input := -1.0

	if _target.has_method("get_throttle_percent"):
		throttle_percent = float(_target.call("get_throttle_percent"))
	if _target.has_method("get_aoa_deg"):
		aoa_deg = float(_target.call("get_aoa_deg"))
	if _target.has_method("get_aoa_limiter_enabled"):
		aoa_limiter_text = "ON" if bool(_target.call("get_aoa_limiter_enabled")) else "OFF"
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
	_aoa_value.text = "%.1f deg" % aoa_deg
	_aoa_limiter_value.text = aoa_limiter_text
	_pitch_input_bar.value = pitch_input * 100.0
	_yaw_input_bar.value = yaw_input * 100.0
	_roll_input_bar.value = roll_input * 100.0
	_throttle_input_bar.value = throttle_input * 100.0
	_update_force_balance_debug()


func _reset_labels() -> void:
	_airspeed_value.text = "--"
	_vertical_speed_value.text = "--"
	_altitude_value.text = "--"
	_throttle_value.text = "--"
	_aoa_value.text = "--"
	_aoa_limiter_value.text = "--"
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


func _reset_force_balance_debug() -> void:
	_force_axis_speed_value.text = "--"
	_thrust_along_value.text = "--"
	_drag_along_value.text = "--"
	_gravity_along_value.text = "--"
	_damping_along_value.text = "--"
	_net_along_value.text = "--"


func _read_snapshot_float(snapshot: Dictionary, key: String) -> float:
	return float(snapshot.get(key, 0.0))
