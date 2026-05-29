extends RigidBody3D

signal local_state_changed(peer_id: int, character_position: Vector3, yaw: float, pitch: float, roll: float)

const AERO_TABLES_STORE := preload("res://scripts/plane_aero_tables_store.gd")

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

@export var air_density: float = 1.225
@export var reference_area: float = 12.0
@export var ambient_wind_velocity_world: Vector3 = Vector3.ZERO
@export var lift_coefficient_table: Array[Vector2] = [
	Vector2(-30.0, -0.65),
	Vector2(-20.0, -0.40),
	Vector2(-10.0, -0.15),
	Vector2(-5.0, -0.05),
	Vector2(0.0, 0.00),
	Vector2(5.0, 0.35),
	Vector2(10.0, 0.75),
	Vector2(15.0, 1.00),
	Vector2(20.0, 0.85),
	Vector2(25.0, 0.55),
	Vector2(30.0, 0.25),
	Vector2(40.0, 0.00),
]
@export var drag_coefficient_table: Array[Vector2] = [
	Vector2(-30.0, 0.30),
	Vector2(-20.0, 0.16),
	Vector2(-10.0, 0.07),
	Vector2(-5.0, 0.04),
	Vector2(0.0, 0.02),
	Vector2(5.0, 0.04),
	Vector2(10.0, 0.07),
	Vector2(15.0, 0.11),
	Vector2(20.0, 0.18),
	Vector2(25.0, 0.26),
	Vector2(30.0, 0.36),
	Vector2(40.0, 0.55),
]
@export var side_force_coefficient_table: Array[Vector2] = [
	Vector2(-40.0, 0.0),
	Vector2(0.0, 0.0),
	Vector2(40.0, 0.0),
]
@export var alignment_strength: float = 5.0
@export var alignment_max_torque: float = 1000.0
@export var network_sync_interval: float = 0.033

const G_BUFFER_SIZE := 10
const TABLE_SORT_EPSILON := 0.0001
const MIN_AERODYNAMIC_SPEED_SQUARED := 0.0001
const MIN_DIRECTION_VECTOR_LENGTH_SQUARED := 0.000001

var peer_id := 1
var is_local_player := false

var roll_input := 0.0
var pitch_input := 0.0
var yaw_input := 0.0
var throttle_input := 0.0

var smoothed_g := 0.0
var aoa_deg := 0.0
var sideslip_deg := 0.0
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
	_sanitize_aero_tables()
	_apply_persisted_aero_tables()
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

	_collect_inputs(delta)
	compute_control_state(delta)
	apply_thrust()
	apply_plane_torque()
	apply_aerodynamic_forces()
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
	var air_velocity_world := _get_air_relative_velocity_world()
	if air_velocity_world.length_squared() < MIN_AERODYNAMIC_SPEED_SQUARED:
		aoa_deg = 0.0
		sideslip_deg = 0.0
		return

	var body_basis := global_transform.basis.orthonormalized()
	var air_velocity_local := body_basis.transposed() * air_velocity_world
	var flow_forward := -air_velocity_local.z
	var flow_up := air_velocity_local.y
	var flow_right := air_velocity_local.x
	var forward_plane_speed := maxf(sqrt(flow_forward * flow_forward + flow_up * flow_up), 0.0001)

	aoa_deg = rad_to_deg(-atan2(flow_up, flow_forward))
	sideslip_deg = rad_to_deg(atan2(flow_right, forward_plane_speed))


func apply_thrust() -> void:
	var throttle := (throttle_input + 1.0) * 0.5
	if throttle <= 0.0:
		return

	apply_central_force(-transform.basis.z * throttle * max_thrust)


func apply_plane_torque() -> void:
	var forward_speed := _get_air_relative_velocity_world().dot(-transform.basis.z)

	var t := maxf(0.0, forward_speed) / maxf(control_effectiveness_speed, 0.001)
	var speed_factor := 1.0
	if aoa_limiter:
		speed_factor = 1.0 / (1.0 + pow(t, 2.0 * speed_assist))
	else:
		speed_factor = 1.0 / (1.0 + pow(t, 2.0 * 0.8))

	var p_in := -pitch_input * speed_factor
	var y_in := yaw_input * speed_factor
	var r_in := roll_input * speed_factor

	var control_torque := base_control_torque + (0.5 * forward_speed * forward_speed * dynamic_torque_scale)
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


func apply_aerodynamic_forces() -> void:
	var air_velocity_world := _get_air_relative_velocity_world()
	var airspeed_squared := air_velocity_world.length_squared()
	if airspeed_squared < MIN_AERODYNAMIC_SPEED_SQUARED:
		return

	var airspeed := sqrt(airspeed_squared)
	if airspeed <= 0.0:
		return
	var airflow_direction := air_velocity_world / airspeed
	var dynamic_pressure := 0.5 * air_density * airspeed_squared

	var lift_coefficient := _sample_aero_table(lift_coefficient_table, aoa_deg)
	var drag_coefficient := maxf(_sample_aero_table(drag_coefficient_table, aoa_deg), 0.0)
	var side_force_coefficient := _sample_aero_table(side_force_coefficient_table, sideslip_deg)

	var drag_force_magnitude := dynamic_pressure * reference_area * drag_coefficient
	var lift_force_magnitude := dynamic_pressure * reference_area * lift_coefficient
	var side_force_magnitude := dynamic_pressure * reference_area * side_force_coefficient

	var right_axis := transform.basis.x
	var lift_axis := right_axis.cross(airflow_direction)
	if lift_axis.length_squared() < MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		lift_axis = transform.basis.y
	else:
		lift_axis = lift_axis.normalized()

	var side_axis := airflow_direction.cross(lift_axis)
	if side_axis.length_squared() < MIN_DIRECTION_VECTOR_LENGTH_SQUARED:
		side_axis = right_axis
	else:
		side_axis = side_axis.normalized()

	var aerodynamic_force := (
		(-airflow_direction * drag_force_magnitude) +
		(lift_axis * lift_force_magnitude) +
		(side_axis * side_force_magnitude)
	)

	if aerodynamic_force.is_finite():
		apply_central_force(aerodynamic_force)

	lift_ok = true


func apply_directional_alignment() -> void:
	var air_velocity_world := _get_air_relative_velocity_world()
	if air_velocity_world.length_squared() < MIN_AERODYNAMIC_SPEED_SQUARED:
		return

	var forward := -transform.basis.z
	var velocity_direction := air_velocity_world.normalized()
	var axis := forward.cross(velocity_direction)
	var angle := forward.angle_to(velocity_direction)

	if angle > 0.01:
		var torque := axis.normalized() * angle * alignment_strength * air_velocity_world.length()
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


func get_lift_table() -> Array[Vector2]:
	return lift_coefficient_table.duplicate()


func get_drag_table() -> Array[Vector2]:
	return drag_coefficient_table.duplicate()


func get_side_force_table() -> Array[Vector2]:
	return side_force_coefficient_table.duplicate()


func set_lift_table(points: Array[Vector2]) -> void:
	lift_coefficient_table = _normalize_table(points)


func set_drag_table(points: Array[Vector2]) -> void:
	drag_coefficient_table = _normalize_table(points)


func set_side_force_table(points: Array[Vector2]) -> void:
	side_force_coefficient_table = _normalize_table(points)


func get_sideslip_deg() -> float:
	return sideslip_deg


func _get_air_relative_velocity_world() -> Vector3:
	return linear_velocity - ambient_wind_velocity_world


func _sample_aero_table(points: Array[Vector2], x_value: float) -> float:
	if points.is_empty():
		return 0.0

	if points.size() == 1:
		return points[0].y

	if x_value <= points[0].x:
		return points[0].y

	var last_index := points.size() - 1
	if x_value >= points[last_index].x:
		return points[last_index].y

	for index in range(last_index):
		var left := points[index]
		var right := points[index + 1]
		if x_value > right.x:
			continue

		var span := right.x - left.x
		if absf(span) <= TABLE_SORT_EPSILON:
			return right.y

		var t := (x_value - left.x) / span
		return lerpf(left.y, right.y, t)

	return points[last_index].y


func _sanitize_aero_tables() -> void:
	lift_coefficient_table = _normalize_table(lift_coefficient_table)
	drag_coefficient_table = _normalize_table(drag_coefficient_table)
	side_force_coefficient_table = _normalize_table(side_force_coefficient_table)


func _normalize_table(points: Array[Vector2]) -> Array[Vector2]:
	var normalized := points.duplicate()
	normalized.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)

	var deduped: Array[Vector2] = []
	for point in normalized:
		if deduped.is_empty():
			deduped.append(point)
			continue

		if absf(point.x - deduped[deduped.size() - 1].x) <= TABLE_SORT_EPSILON:
			deduped[deduped.size() - 1] = point
		else:
			deduped.append(point)

	return deduped


func _apply_persisted_aero_tables() -> void:
	var payload: Dictionary = AERO_TABLES_STORE.load_payload()
	if payload.is_empty():
		return

	var lift_points := AERO_TABLES_STORE.decode_points(payload.get("lift_table", []))
	if not lift_points.is_empty():
		set_lift_table(lift_points)

	var drag_points := AERO_TABLES_STORE.decode_points(payload.get("drag_table", []))
	if not drag_points.is_empty():
		set_drag_table(drag_points)
