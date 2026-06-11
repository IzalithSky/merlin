extends Node3D

signal local_state_changed(peer_id: int, snapshot: Dictionary)

@export var move_speed: float = 1200.0
@export var mouse_sensitivity: float = 0.002
@export var acceleration: float = 2400.0
@export var deceleration: float = 36.0

const MAX_PITCH := deg_to_rad(89.0)
const MIN_VELOCITY_SQ := 0.0001

@onready var _camera: Camera3D = %Camera3D

var peer_id := 1
var is_local_player := false
var _yaw := 0.0
var _pitch := 0.0
var _velocity := Vector3.ZERO
var _snapshot_tick := 0


func _ready() -> void:
	add_to_group("player_character")
	_yaw = rotation.y
	_pitch = clamp(_camera.rotation.x, -MAX_PITCH, MAX_PITCH)
	_apply_look_rotation()
	_apply_local_player_mode()


func configure(new_peer_id: int, local_player: bool) -> void:
	peer_id = new_peer_id
	is_local_player = local_player

	if is_node_ready():
		_apply_local_player_mode()


func _unhandled_input(event: InputEvent) -> void:
	if not is_local_player:
		return

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
		_apply_look_rotation()
		_emit_local_state()


func _process(delta: float) -> void:
	if not is_local_player:
		return

	var can_move := not _is_game_menu_open() and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED

	var desired_velocity := Vector3.ZERO

	if can_move:
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

		if input_vector != Vector3.ZERO:
			input_vector = input_vector.normalized()
			var yaw_basis := Basis(Vector3.UP, _yaw)
			var world_direction := (
				yaw_basis.x * input_vector.x
				+ Vector3.UP * input_vector.y
				- yaw_basis.z * input_vector.z
			)
			desired_velocity = world_direction * move_speed

	var accel_rate := acceleration if desired_velocity != Vector3.ZERO else deceleration
	_velocity = _velocity.move_toward(desired_velocity, accel_rate * delta)
	if _velocity.length_squared() < MIN_VELOCITY_SQ and desired_velocity == Vector3.ZERO:
		_velocity = Vector3.ZERO

	if _velocity == Vector3.ZERO:
		return

	global_position += _velocity * delta
	_emit_local_state()


func apply_remote_state(snapshot: Dictionary) -> void:
	var target_position_world: Vector3 = snapshot.get("position", global_position)
	var rotation_quaternion: Quaternion = snapshot.get(
		"rotation",
		Basis.from_euler(Vector3(_pitch, _yaw, 0.0)).get_rotation_quaternion()
	)
	global_position = target_position_world
	var euler := Basis(rotation_quaternion.normalized()).get_euler()
	_yaw = euler.y
	_pitch = clamp(euler.x, -MAX_PITCH, MAX_PITCH)
	_apply_look_rotation()


func apply_spawn_state(character_position: Vector3, yaw: float) -> void:
	global_position = character_position
	_yaw = yaw

	if is_node_ready():
		_apply_look_rotation()
	else:
		rotation.y = _yaw


func _apply_look_rotation() -> void:
	rotation.y = _yaw
	_camera.rotation = Vector3(_pitch, 0.0, 0.0)


func _apply_local_player_mode() -> void:
	_camera.current = is_local_player

	if is_local_player:
		call_deferred("_capture_mouse")


func _capture_mouse() -> void:
	if not is_local_player or _is_game_menu_open() or not DisplayServer.window_is_focused():
		return

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _emit_local_state() -> void:
	_snapshot_tick += 1
	local_state_changed.emit(peer_id, {
		"tick": _snapshot_tick,
		"position": global_position,
		"rotation": Quaternion(Basis.from_euler(Vector3(_pitch, _yaw, 0.0)).orthonormalized()),
		"linear_velocity": _velocity,
	})


func _is_game_menu_open() -> bool:
	for menu in get_tree().get_nodes_in_group("game_menu"):
		if menu.has_method("is_open") and menu.is_open():
			return true
	return false
