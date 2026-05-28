extends RigidBody3D

signal local_state_changed(peer_id: int, character_position: Vector3, yaw: float, pitch: float, roll: float)

@export var rot_rate: float = 2.4
@export var rot_decay: float = 3.0
@export var thr_rate: float = 1.2
@export var control_effectiveness_speed: float = 50.0

@export var max_thrust: float = 18000.0
@export var max_pitch: float = 0.8
@export var max_yaw: float = 0.1
@export var max_roll: float = 1.0
@export var speed_assist: float = 1.4
@export var aoa_limiter: bool = true
@export var base_control_torque: float = 220000.0
@export var dynamic_torque_scale: float = 180.0

@export var lift_coefficient: float = 0.0
@export var stall_aoa_deg: float = 30.0
@export var drag_forward: float = 0.005
@export var drag_up: float = 0.05
@export var drag_side: float = 0.025
@export var alignment_strength: float = 5000.0
@export var alignment_max_torque: float = 350000.0
@export var network_sync_interval: float = 0.033

const G_BUFFER_SIZE := 10

var peer_id := 1
var is_local_player := false

var roll_input := 0.0
var pitch_input := 0.0
var yaw_input := 0.0
var throttle_input := 0.0

var smoothed_g := 0.0
var aoa_deg := 0.0
var horizontal_aoa_deg := 0.0
var throttle_percent := 0.0
var lift_ok := true

var _g_force_buffer: Array[float] = []
var _prev_velocity := Vector3.ZERO
var _sync_timer := 0.0


func _ready() -> void:
	add_to_group("player_character")
	throttle_input = -1.0
	_apply_local_player_mode()


func configure(new_peer_id: int, local_player: bool) -> void:
	peer_id = new_peer_id
	is_local_player = local_player

	if is_node_ready():
		_apply_local_player_mode()


func _physics_process(delta: float) -> void:
	if not is_local_player:
		return

	if _is_game_menu_open():
		return

	_collect_inputs(delta)
	compute_control_state(delta)
	apply_thrust()
	apply_plane_torque()
	apply_lift()
	apply_air_drag()
	apply_directional_alignment()

	_sync_timer += delta
	if _sync_timer >= max(network_sync_interval, 0.001):
		_sync_timer = 0.0
		_emit_local_state()


func _collect_inputs(delta: float) -> void:
	var rotation_rate := rot_rate * delta
	var rotation_decay := rot_decay * delta

	if Input.is_physical_key_pressed(KEY_D):
		roll_input -= rotation_rate
	elif Input.is_physical_key_pressed(KEY_A):
		roll_input += rotation_rate
	else:
		roll_input = move_toward(roll_input, 0.0, rotation_decay)
	roll_input = clamp(roll_input, -1.0, 1.0)

	var keyboard_pitch := 0.0
	if Input.is_physical_key_pressed(KEY_W):
		keyboard_pitch += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		keyboard_pitch -= 1.0

	var keyboard_yaw := 0.0
	if Input.is_physical_key_pressed(KEY_Q):
		keyboard_yaw += 1.0
	if Input.is_physical_key_pressed(KEY_E):
		keyboard_yaw -= 1.0

	var desired_pitch: float = clampf(keyboard_pitch, -1.0, 1.0)
	var desired_yaw: float = clampf(keyboard_yaw, -1.0, 1.0)

	if absf(desired_pitch) > 0.001:
		pitch_input = move_toward(pitch_input, desired_pitch, rotation_rate)
	else:
		pitch_input = move_toward(pitch_input, 0.0, rotation_decay)

	if absf(desired_yaw) > 0.001:
		yaw_input = move_toward(yaw_input, desired_yaw, rotation_rate)
	else:
		yaw_input = move_toward(yaw_input, 0.0, rotation_decay)

	pitch_input = clamp(pitch_input, -1.0, 1.0)
	yaw_input = clamp(yaw_input, -1.0, 1.0)

	var throttle_rate := thr_rate * delta
	if Input.is_physical_key_pressed(KEY_SPACE):
		throttle_input += throttle_rate
	else:
		throttle_input = move_toward(throttle_input, -1.0, throttle_rate)
	throttle_input = clamp(throttle_input, -1.0, 1.0)

	throttle_percent = ((throttle_input + 1.0) * 0.5) * 100.0


func compute_control_state(delta: float) -> void:
	compute_aoa()
	update_g_force(delta)


func update_g_force(delta: float) -> void:
	if delta <= 0.0:
		return

	var gravity: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector")
	var g_force := ((linear_velocity - _prev_velocity) / delta - gravity).length() / 9.80665
	_g_force_buffer.append(g_force)
	if _g_force_buffer.size() > G_BUFFER_SIZE:
		_g_force_buffer.pop_front()

	var sum := 0.0
	for value in _g_force_buffer:
		sum += value
	smoothed_g = sum / float(max(_g_force_buffer.size(), 1))
	_prev_velocity = linear_velocity


func compute_aoa() -> void:
	var velocity := linear_velocity
	if velocity.length() < 0.001:
		aoa_deg = 0.0
		horizontal_aoa_deg = 0.0
		return

	var forward := -transform.basis.z
	var up := transform.basis.y
	var right := transform.basis.x
	var velocity_direction := velocity.normalized()

	aoa_deg = rad_to_deg(-atan2(velocity_direction.dot(up), velocity_direction.dot(forward)))
	horizontal_aoa_deg = rad_to_deg(atan2(velocity_direction.dot(right), velocity_direction.dot(forward)))


func apply_thrust() -> void:
	var throttle := (throttle_input + 1.0) * 0.5
	if throttle <= 0.0:
		return

	apply_central_force(-transform.basis.z * throttle * max_thrust)


func apply_plane_torque() -> void:
	var forward_speed := linear_velocity.dot(-transform.basis.z)
	var q := 0.5 * forward_speed * forward_speed

	var t := maxf(0.0, forward_speed) / maxf(control_effectiveness_speed, 0.001)
	var speed_factor := 1.0
	if aoa_limiter:
		speed_factor = 1.0 / (1.0 + pow(t, 2.0 * speed_assist))
	else:
		speed_factor = 1.0 / (1.0 + pow(t, 2.0 * 0.8))

	var p_in := -pitch_input * speed_factor
	var y_in := yaw_input * speed_factor
	var r_in := roll_input * speed_factor

	var control_torque := base_control_torque + (q * dynamic_torque_scale)

	apply_torque(transform.basis.x * p_in * control_torque * max_pitch)
	apply_torque(transform.basis.y * y_in * control_torque * max_yaw)
	apply_torque(transform.basis.z * r_in * control_torque * max_roll)


func apply_lift() -> void:
	var velocity := linear_velocity
	if velocity.length() < 0.001:
		return

	var dynamic_pressure := 0.5 * velocity.length_squared()
	var vertical_cl := lift_coefficient + (2.0 * PI * deg_to_rad(aoa_deg))
	var lateral_cl := -2.0 * PI * deg_to_rad(horizontal_aoa_deg)

	lift_ok = absf(aoa_deg) < stall_aoa_deg and absf(horizontal_aoa_deg) < stall_aoa_deg
	if not lift_ok:
		return

	apply_central_force(transform.basis.y * dynamic_pressure * vertical_cl)
	apply_central_force(transform.basis.x * dynamic_pressure * lateral_cl)


func apply_air_drag() -> void:
	var velocity := linear_velocity
	if velocity.length_squared() < 0.0001:
		return

	var local_basis := transform.basis
	var drag := Vector3.ZERO
	drag += -local_basis.z * velocity.dot(local_basis.z) * absf(velocity.dot(local_basis.z)) * drag_forward
	drag += -local_basis.y * velocity.dot(local_basis.y) * absf(velocity.dot(local_basis.y)) * drag_up
	drag += -local_basis.x * velocity.dot(local_basis.x) * absf(velocity.dot(local_basis.x)) * drag_side

	if drag.is_finite():
		apply_central_force(drag)


func apply_directional_alignment() -> void:
	var velocity := linear_velocity
	if velocity.length() < 0.001:
		return

	var forward := -transform.basis.z
	var velocity_direction := velocity.normalized()
	var axis := forward.cross(velocity_direction)
	var angle := forward.angle_to(velocity_direction)

	if angle > 0.01:
		var torque := axis.normalized() * angle * alignment_strength * velocity.length()
		if alignment_max_torque > 0.0:
			torque = torque.limit_length(alignment_max_torque)
		apply_torque(torque)


func apply_remote_state(character_position: Vector3, yaw: float, pitch: float, roll: float) -> void:
	if is_local_player:
		return

	global_position = character_position
	rotation = Vector3(pitch, yaw, roll)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func apply_spawn_state(character_position: Vector3, yaw: float) -> void:
	global_position = character_position
	rotation = Vector3(0.0, yaw, 0.0)


func _apply_local_player_mode() -> void:
	freeze = not is_local_player

	if is_local_player:
		sleeping = false
		can_sleep = false
	else:
		roll_input = 0.0
		pitch_input = 0.0
		yaw_input = 0.0
		throttle_input = -1.0


func _emit_local_state() -> void:
	var euler := global_transform.basis.get_euler()
	local_state_changed.emit(peer_id, global_position, euler.y, euler.x, euler.z)


func _is_game_menu_open() -> bool:
	for menu in get_tree().get_nodes_in_group("game_menu"):
		if menu.has_method("is_open") and menu.is_open():
			return true
	return false
