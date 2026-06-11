extends Node3D

signal detached

@export var camera_max_pitch_deg: float = 89.0
@export var camera_zoom_step: float = 4.0
@export var camera_min_fov: float = 20.0
@export var camera_max_fov: float = 90.0
@export var follow_lerp_speed: float = 0.0
@export var shot_down_detach_delay_sec: float = 2.0

@onready var _camera: Camera3D = %Camera3D
@onready var _camera_yaw_pivot: Node3D = %CameraYawPivot
@onready var _camera_pitch_pivot: Node3D = %CameraPitchPivot

var _target: Node3D
var _camera_yaw := 0.0
var _camera_pitch := 0.0
var _shot_down_detach_deadline := -1.0
var _is_detached := false
var _first_person := false
var _third_person_camera_transform := Transform3D.IDENTITY
var _mouse_sensitivity: float = 0.006


func _ready() -> void:
	_third_person_camera_transform = _camera.transform
	_camera_yaw = _camera_yaw_pivot.rotation.y
	_camera_pitch = _camera_pitch_pivot.rotation.x
	_apply_camera_look()
	_sync_sensitivity_from_settings()
	var ds := get_node_or_null("/root/DisplaySettings")
	if ds != null and ds.has_signal("settings_changed"):
		ds.settings_changed.connect(_sync_sensitivity_from_settings)


func _sync_sensitivity_from_settings() -> void:
	var ds := get_node_or_null("/root/DisplaySettings")
	if ds == null:
		return
	var val: Variant = ds.get("mouse_sensitivity")
	if val is float:
		_mouse_sensitivity = val


func get_camera() -> Camera3D:
	return _camera


func set_target(target: Node3D = null) -> void:
	_set_first_person(false)
	_target = target
	_is_detached = false
	_shot_down_detach_deadline = -1.0
	if _target != null:
		global_position = _target.global_position
		global_transform.basis = _target.global_transform.basis.orthonormalized()
		call_deferred("_capture_mouse")
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _unhandled_input(event: InputEvent) -> void:
	if _target == null and not _is_detached:
		return

	if _is_game_menu_open():
		return

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	if event.is_action_pressed("toggle_camera_view") and _target != null and not _is_detached:
		_set_first_person(not _first_person)
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
		_camera_yaw -= event.relative.x * _mouse_sensitivity
		_camera_pitch -= event.relative.y * _mouse_sensitivity
		var max_pitch := deg_to_rad(camera_max_pitch_deg)
		_camera_pitch = clampf(_camera_pitch, -max_pitch, max_pitch)
		_apply_camera_look()


func _physics_process(delta: float) -> void:
	if _is_detached:
		return

	if _target == null:
		return

	if not is_instance_valid(_target):
		_target = null
		_shot_down_detach_deadline = -1.0
		return

	var target_shot_down: bool = _target.get("is_shot_down") == true
	if target_shot_down:
		if _shot_down_detach_deadline < 0.0:
			if shot_down_detach_delay_sec <= 0.0:
				_detach_from_target()
				return
			_shot_down_detach_deadline = Time.get_ticks_msec() / 1000.0 + shot_down_detach_delay_sec
		elif (Time.get_ticks_msec() / 1000.0) >= _shot_down_detach_deadline:
			_detach_from_target()
			return
	else:
		_shot_down_detach_deadline = -1.0

	var target_position := _target.global_position
	if follow_lerp_speed <= 0.0:
		global_position = target_position
	else:
		var blend := clampf(follow_lerp_speed * delta, 0.0, 1.0)
		global_position = global_position.lerp(target_position, blend)
	global_transform.basis = _target.global_transform.basis.orthonormalized()


func _detach_from_target() -> void:
	_set_first_person(false)
	_target = null
	_shot_down_detach_deadline = -1.0
	_is_detached = true

	if _camera_pitch_pivot == null:
		detached.emit()
		return

	# Capture world-space look direction before changing the rig basis.
	# world_fwd = (-sin(yaw)*cos(pitch), sin(pitch), -cos(yaw)*cos(pitch))
	# so we can recover yaw/pitch for an identity-basis rig.
	var world_fwd := -_camera_pitch_pivot.global_transform.basis.z

	# Level the rig to global upright.
	global_transform.basis = Basis.IDENTITY

	# Decompose world_fwd back into yaw and pitch so the camera keeps
	# pointing the same direction after the basis reset.
	_camera_pitch = asin(clampf(world_fwd.y, -1.0, 1.0))
	_camera_yaw = atan2(-world_fwd.x, -world_fwd.z)
	_apply_camera_look()
	detached.emit()


func _set_first_person(value: bool) -> void:
	_first_person = value
	if is_node_ready():
		_camera.transform = Transform3D.IDENTITY if _first_person else _third_person_camera_transform
	if _target != null:
		var body_mesh := _target.get_node_or_null("BodyMesh") as MeshInstance3D
		if body_mesh != null:
			body_mesh.visible = not _first_person


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
