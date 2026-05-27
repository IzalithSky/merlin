extends Camera3D

@export var move_speed: float = 1200.0
@export var mouse_sensitivity: float = 0.002

const MAX_PITCH := deg_to_rad(89.0)

var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	_yaw = rotation.y
	_pitch = clamp(rotation.x, -MAX_PITCH, MAX_PITCH)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _unhandled_input(event: InputEvent) -> void:
	if _is_game_menu_open():
		return

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	if event is InputEventMouseButton and event.pressed:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, -MAX_PITCH, MAX_PITCH)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	if _is_game_menu_open() or Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return

	var input_vector := Vector3.ZERO

	if Input.is_physical_key_pressed(KEY_D):
		input_vector.x += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		input_vector.x -= 1.0
	if Input.is_physical_key_pressed(KEY_R):
		input_vector.y += 1.0
	if Input.is_physical_key_pressed(KEY_F):
		input_vector.y -= 1.0
	if Input.is_physical_key_pressed(KEY_W):
		input_vector.z += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		input_vector.z -= 1.0

	if input_vector == Vector3.ZERO:
		return

	input_vector = input_vector.normalized()
	var yaw_basis := Basis(Vector3.UP, _yaw)
	var world_direction := (
		yaw_basis.x * input_vector.x
		+ Vector3.UP * input_vector.y
		- yaw_basis.z * input_vector.z
	)
	global_position += world_direction * move_speed * delta


func _is_game_menu_open() -> bool:
	for menu in get_tree().get_nodes_in_group("game_menu"):
		if menu.has_method("is_open") and menu.is_open():
			return true
	return false
