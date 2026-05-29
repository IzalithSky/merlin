extends CanvasLayer

@onready var _airspeed_value: Label = %AirspeedValue
@onready var _vertical_speed_value: Label = %VerticalSpeedValue
@onready var _altitude_value: Label = %AltitudeValue
@onready var _throttle_value: Label = %ThrottleValue
@onready var _aoa_value: Label = %AoaValue
@onready var _pitch_input_bar: ProgressBar = %PitchInputBar
@onready var _yaw_input_bar: ProgressBar = %YawInputBar
@onready var _roll_input_bar: ProgressBar = %RollInputBar
@onready var _throttle_input_bar: ProgressBar = %ThrottleInputBar

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
	_aoa_value.text = "%.1f deg" % aoa_deg
	_pitch_input_bar.value = pitch_input * 100.0
	_yaw_input_bar.value = yaw_input * 100.0
	_roll_input_bar.value = roll_input * 100.0
	_throttle_input_bar.value = throttle_input * 100.0


func _reset_labels() -> void:
	_airspeed_value.text = "--"
	_vertical_speed_value.text = "--"
	_altitude_value.text = "--"
	_throttle_value.text = "--"
	_aoa_value.text = "--"
	_pitch_input_bar.value = 0.0
	_yaw_input_bar.value = 0.0
	_roll_input_bar.value = 0.0
	_throttle_input_bar.value = -100.0
