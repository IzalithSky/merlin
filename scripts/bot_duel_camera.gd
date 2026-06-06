extends Node3D

@export var mouse_sensitivity: float = 0.006
@export var max_pitch_deg: float = 80.0
@export var target_height: float = 8.0
@export var camera_distance: float = 180.0
@export var min_distance: float = 35.0
@export var max_distance: float = 800.0
@export var zoom_step: float = 25.0
@export var follow_lerp_speed: float = 0.0

@onready var _camera: Camera3D = %Camera3D

var _targets: Array[Node3D] = []
var _target_index := 0
var _yaw := 0.0
var _pitch := deg_to_rad(-12.0)


func _ready() -> void:
	_camera.current = true
	_snap_to_current_target()
	call_deferred("_capture_mouse")


func set_targets(new_targets: Array[Node3D]) -> void:
	_targets.clear()
	for target_node in new_targets:
		if is_instance_valid(target_node):
			_targets.append(target_node)

	_target_index = clampi(_target_index, 0, maxi(_targets.size() - 1, 0))
	_snap_to_current_target()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_cycle_target()
				_capture_mouse()
			MOUSE_BUTTON_WHEEL_UP:
				camera_distance = clampf(camera_distance - zoom_step, min_distance, max_distance)
			MOUSE_BUTTON_WHEEL_DOWN:
				camera_distance = clampf(camera_distance + zoom_step, min_distance, max_distance)
			_:
				_capture_mouse()
		return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		var max_pitch := deg_to_rad(max_pitch_deg)
		_pitch = clampf(_pitch, -max_pitch, max_pitch)


func _physics_process(delta: float) -> void:
	_update_camera_transform(delta)


func _cycle_target() -> void:
	if _targets.is_empty():
		return

	_target_index = (_target_index + 1) % _targets.size()
	_snap_to_current_target()


func _capture_mouse() -> void:
	if not DisplayServer.window_is_focused():
		return

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _snap_to_current_target() -> void:
	_update_camera_transform(0.0, true)


func _update_camera_transform(delta: float, snap: bool = false) -> void:
	var current_target := _get_current_target()
	if current_target == null:
		return

	var look_position := current_target.global_position + Vector3.UP * target_height
	var desired_position := _get_orbit_position(look_position)
	if snap or follow_lerp_speed <= 0.0:
		global_position = desired_position
	else:
		var blend := clampf(follow_lerp_speed * delta, 0.0, 1.0)
		global_position = global_position.lerp(desired_position, blend)

	look_at(look_position, Vector3.UP)


func _get_orbit_position(look_position: Vector3) -> Vector3:
	var orbit_basis := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	return look_position + orbit_basis * Vector3(0.0, 0.0, camera_distance)


func _get_current_target() -> Node3D:
	while _target_index < _targets.size():
		var current_target := _targets[_target_index]
		if is_instance_valid(current_target):
			return current_target

		_targets.remove_at(_target_index)

	if not _targets.is_empty():
		_target_index = 0
		return _targets[0]

	return null
