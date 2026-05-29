extends RigidBody3D

signal local_state_changed(peer_id: int, character_position: Vector3, yaw: float, pitch: float, roll: float)

@export var rot_rate: float = 2.4
@export var rot_decay: float = 3.0
@export var thr_rate: float = 1.2
@export var control_effectiveness_speed: float = 50.0

@export var max_thrust: float = 8000.0
@export var max_pitch: float = 0.8
@export var max_yaw: float = 0.1
@export var max_roll: float = 1.0
@export var speed_assist: float = 1.4
@export var aoa_limiter: bool = true
@export var base_control_torque: float = 4000.0
@export var dynamic_torque_scale: float = 3.0

@export var lift_coefficient: float = 0.0
@export var stall_aoa_deg: float = 30.0
@export var drag_forward: float = 0.005
@export var drag_up: float = 0.05
@export var drag_side: float = 0.025
@export var alignment_strength: float = 5.0
@export var alignment_max_torque: float = 1000.0
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
var _cached_control_half_extents := Vector3.ONE
var _control_half_extents_dirty := true


func _ready() -> void:
	add_to_group("player_character")
	throttle_input = -1.0
	_ensure_control_geometry_cache_connections()
	_refresh_control_half_extents_cache()
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
	if Input.is_physical_key_pressed(KEY_SHIFT):
		throttle_input -= throttle_rate
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
	var pitch_torque := p_in * control_torque * max_pitch
	var yaw_torque := y_in * control_torque * max_yaw
	var roll_torque := r_in * control_torque * max_roll
	if _control_half_extents_dirty:
		_refresh_control_half_extents_cache()
	var half_extents := _cached_control_half_extents
	var roll_offset := maxf(half_extents.x, 0.05)
	var tail_offset := maxf(half_extents.z, 0.05)

	# Roll: force couple at side edges.
	_apply_local_torque_force_pair(
		Vector3(0.0, 0.0, roll_torque),
		Vector3(roll_offset, 0.0, 0.0)
	)
	# Pitch + yaw: force couple anchored on rear lever arm.
	_apply_local_torque_force_pair(
		Vector3(pitch_torque, yaw_torque, 0.0),
		Vector3(0.0, 0.0, tail_offset)
	)


func _apply_local_torque_force_pair(local_torque: Vector3, local_offset: Vector3) -> void:
	if local_torque.length_squared() < 0.000001:
		return

	if local_offset.length_squared() < 0.000001:
		return

	var world_basis := global_transform.basis.orthonormalized()
	var world_torque := world_basis * local_torque
	var world_offset := world_basis * local_offset
	var world_offset_len_sq := world_offset.length_squared()
	if world_offset_len_sq < 0.000001:
		return

	# For a force pair at +/-r with +/-F:
	# total torque = 2 * (r x F) => F = (tau x r) / (2 * |r|^2)
	var world_force := world_torque.cross(world_offset) / (2.0 * world_offset_len_sq)
	if not world_force.is_finite():
		return

	apply_force(world_force, world_offset)
	apply_force(-world_force, -world_offset)


func _ensure_control_geometry_cache_connections() -> void:
	if not child_entered_tree.is_connected(_on_child_entered_tree):
		child_entered_tree.connect(_on_child_entered_tree)
	if not child_exiting_tree.is_connected(_on_child_exiting_tree):
		child_exiting_tree.connect(_on_child_exiting_tree)

	for child in get_children():
		var collider := child as CollisionShape3D
		if collider != null:
			_watch_collision_shape_resource(collider)


func _on_child_entered_tree(node: Node) -> void:
	var collider := node as CollisionShape3D
	if collider == null:
		return
	_watch_collision_shape_resource(collider)
	_mark_control_half_extents_dirty()


func _on_child_exiting_tree(node: Node) -> void:
	if node is CollisionShape3D:
		_mark_control_half_extents_dirty()


func _watch_collision_shape_resource(collider: CollisionShape3D) -> void:
	if collider.shape == null:
		return
	if not collider.shape.changed.is_connected(_on_collision_shape_resource_changed):
		collider.shape.changed.connect(_on_collision_shape_resource_changed)


func _on_collision_shape_resource_changed() -> void:
	_mark_control_half_extents_dirty()


func _mark_control_half_extents_dirty() -> void:
	_control_half_extents_dirty = true


func _refresh_control_half_extents_cache() -> void:
	for child in get_children():
		var collider := child as CollisionShape3D
		if collider != null:
			_watch_collision_shape_resource(collider)
	_cached_control_half_extents = _get_body_half_extents_from_collision()
	_control_half_extents_dirty = false


func _get_body_half_extents_from_collision() -> Vector3:
	var min_bounds := Vector3(1.0e20, 1.0e20, 1.0e20)
	var max_bounds := Vector3(-1.0e20, -1.0e20, -1.0e20)
	var has_bounds := false

	for child in get_children():
		var collider := child as CollisionShape3D
		if collider == null or collider.disabled or collider.shape == null:
			continue

		var shape_half_extents := _get_shape_half_extents(collider.shape)
		if shape_half_extents.length_squared() <= 0.0:
			continue

		var local_transform := collider.transform
		var corners: Array[Vector3] = [
			Vector3(-shape_half_extents.x, -shape_half_extents.y, -shape_half_extents.z),
			Vector3(-shape_half_extents.x, -shape_half_extents.y, shape_half_extents.z),
			Vector3(-shape_half_extents.x, shape_half_extents.y, -shape_half_extents.z),
			Vector3(-shape_half_extents.x, shape_half_extents.y, shape_half_extents.z),
			Vector3(shape_half_extents.x, -shape_half_extents.y, -shape_half_extents.z),
			Vector3(shape_half_extents.x, -shape_half_extents.y, shape_half_extents.z),
			Vector3(shape_half_extents.x, shape_half_extents.y, -shape_half_extents.z),
			Vector3(shape_half_extents.x, shape_half_extents.y, shape_half_extents.z),
		]

		for corner: Vector3 in corners:
			var local_point: Vector3 = local_transform * corner
			min_bounds = min_bounds.min(local_point)
			max_bounds = max_bounds.max(local_point)
			has_bounds = true

	if not has_bounds:
		return Vector3(1.0, 1.0, 1.0)

	return (max_bounds - min_bounds) * 0.5


func _get_shape_half_extents(shape_resource: Shape3D) -> Vector3:
	if shape_resource is BoxShape3D:
		var box := shape_resource as BoxShape3D
		return box.size * 0.5

	if shape_resource is SphereShape3D:
		var sphere := shape_resource as SphereShape3D
		return Vector3.ONE * sphere.radius

	if shape_resource is CapsuleShape3D:
		var capsule := shape_resource as CapsuleShape3D
		return Vector3(capsule.radius, capsule.height * 0.5, capsule.radius)

	if shape_resource is CylinderShape3D:
		var cylinder := shape_resource as CylinderShape3D
		return Vector3(cylinder.radius, cylinder.height * 0.5, cylinder.radius)

	if shape_resource is ConvexPolygonShape3D:
		var convex := shape_resource as ConvexPolygonShape3D
		var points := convex.points
		if points.is_empty():
			return Vector3.ZERO
		var min_point := points[0]
		var max_point := points[0]
		for point in points:
			min_point = min_point.min(point)
			max_point = max_point.max(point)
		return (max_point - min_point) * 0.5

	if shape_resource is ConcavePolygonShape3D:
		var concave := shape_resource as ConcavePolygonShape3D
		var faces := concave.get_faces()
		if faces.is_empty():
			return Vector3.ZERO
		var min_face := faces[0]
		var max_face := faces[0]
		for face_vertex in faces:
			min_face = min_face.min(face_vertex)
			max_face = max_face.max(face_vertex)
		return (max_face - min_face) * 0.5

	return Vector3.ZERO


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


func get_throttle_percent() -> float:
	return throttle_percent


func get_aoa_deg() -> float:
	return aoa_deg


func get_pitch_input() -> float:
	return pitch_input


func get_yaw_input() -> float:
	return yaw_input


func get_roll_input() -> float:
	return roll_input


func get_throttle_input() -> float:
	return throttle_input
