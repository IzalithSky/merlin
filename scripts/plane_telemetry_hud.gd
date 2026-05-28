extends CanvasLayer

@onready var _airspeed_value: Label = %AirspeedValue
@onready var _vertical_speed_value: Label = %VerticalSpeedValue
@onready var _altitude_value: Label = %AltitudeValue

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

	_airspeed_value.text = "%.1f m/s" % airspeed_forward
	_vertical_speed_value.text = "%.1f m/s" % vertical_speed
	_altitude_value.text = "%.1f m" % altitude


func _reset_labels() -> void:
	_airspeed_value.text = "--"
	_vertical_speed_value.text = "--"
	_altitude_value.text = "--"
