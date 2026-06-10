extends Node3D

@export var mouse_sensitivity: float = 0.006
@export var camera_max_pitch_deg: float = 89.0
@export var camera_zoom_step: float = 4.0
@export var camera_min_fov: float = 20.0
@export var camera_max_fov: float = 90.0
@export var follow_lerp_speed: float = 0.0

@onready var _camera: Camera3D = %Camera3D
@onready var _camera_yaw_pivot: Node3D = %CameraYawPivot
@onready var _camera_pitch_pivot: Node3D = %CameraPitchPivot

var _target: Node3D
var _camera_yaw := 0.0
var _camera_pitch := 0.0


func _ready() -> void:
	_camera_yaw = _camera_yaw_pivot.rotation.y
	_camera_pitch = _camera_pitch_pivot.rotation.x
	_apply_camera_look()


func get_camera() -> Camera3D:
	return _camera


func set_target(target: Node3D = null) -> void:
	_target = target
	if _target != null:
		global_position = _target.global_position
		call_deferred("_capture_mouse")
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _unhandled_input(event: InputEvent) -> void:
	if _target == null:
		return

	if _is_game_menu_open():
		return

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.fov = clampf(_camera.fov - camera_zoom_step, camera_min_fov, camera_max_fov)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.fov = clampf(_camera.fov + camera_zoom_step, camera_min_fov, camera_max_fov)
			return
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_camera_yaw -= event.relative.x * mouse_sensitivity
		_camera_pitch -= event.relative.y * mouse_sensitivity
		var max_pitch := deg_to_rad(camera_max_pitch_deg)
		_camera_pitch = clampf(_camera_pitch, -max_pitch, max_pitch)
		_apply_camera_look()


func _physics_process(delta: float) -> void:
	if _target == null:
		return

	if not is_instance_valid(_target):
		_target = null
		return

	var target_position := _target.global_position
	if follow_lerp_speed <= 0.0:
		global_position = target_position
	else:
		var blend := clampf(follow_lerp_speed * delta, 0.0, 1.0)
		global_position = global_position.lerp(target_position, blend)
	global_transform.basis = _target.global_transform.basis.orthonormalized()


func _capture_mouse() -> void:
	if _target == null or _is_game_menu_open() or not DisplayServer.window_is_focused():
		return

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _apply_camera_look() -> void:
	_camera_yaw_pivot.rotation.y = _camera_yaw
	_camera_pitch_pivot.rotation.x = _camera_pitch


func _is_game_menu_open() -> bool:
	for menu in get_tree().get_nodes_in_group("game_menu"):
		if menu.has_method("is_open") and menu.is_open():
			return true
	return false
