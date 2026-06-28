class_name PlaneForceDebugAdapter
extends RefCounted

var _plane: PlaneCharacter


func _init(plane: PlaneCharacter) -> void:
	_plane = plane


func ensure_renderer() -> void:
	if not _plane.debug_force_vectors_enabled:
		return

	if _plane._force_debug_renderer != null:
		return

	_plane._force_debug_renderer = _plane.FORCE_DEBUG_RENDERER_SCRIPT.new()
	_plane._force_debug_renderer.name = "ForceDebugRenderer3D"
	_plane.add_child(_plane._force_debug_renderer)
	update_renderer_state()


func update_renderer_state() -> void:
	if _plane._force_debug_renderer == null:
		return

	# Disabled entirely: free the node so it stops consuming a tree slot and its
	# per-frame work disappears. ensure_renderer() recreates it if re-enabled.
	if not _plane.debug_force_vectors_enabled:
		_plane._force_debug_renderer.queue_free()
		_plane._force_debug_renderer = null
		return

	var should_show := _plane._is_simulated_locally()
	_plane._force_debug_renderer.visible = should_show
	if not should_show:
		_plane._force_debug_renderer.clear_frame()


func _is_rendering() -> bool:
	return _plane._force_debug_renderer != null and _plane._force_debug_renderer.visible


func begin_frame() -> void:
	_plane.reset_debug_force_accumulators()

	# Skip all accumulation/mesh work unless the arrows are actually being drawn.
	if not _is_rendering():
		return

	_plane._force_debug_renderer.begin_frame()
	var gravity_force := _plane._get_gravity_force_world()
	_plane.set_debug_gravity_force_world(gravity_force)
	push_force(_plane.global_position, gravity_force, _plane.DEBUG_COLOR_GRAVITY)


func end_frame() -> void:
	if not _is_rendering():
		return

	_plane._force_debug_renderer.end_frame()


func clear_frame() -> void:
	if _plane._force_debug_renderer == null:
		return

	_plane._force_debug_renderer.clear_frame()


func push_force(origin_world: Vector3, force_world: Vector3, color: Color) -> void:
	if not _is_rendering():
		return

	_plane._force_debug_renderer.push_force(origin_world, force_world, color)


func push_torque(origin_world: Vector3, torque_world: Vector3, color: Color) -> void:
	if not _is_rendering():
		return

	_plane._force_debug_renderer.push_torque(origin_world, torque_world, color)


func get_force_balance_snapshot() -> Dictionary:
	var velocity := _plane.linear_velocity
	var speed := velocity.length()
	var velocity_dir := Vector3.ZERO
	if speed > 0.001:
		velocity_dir = velocity / speed

	var force_terms := _plane.get_debug_force_balance_terms()
	var thrust_force: Vector3 = force_terms["thrust"]
	var lift_force: Vector3 = force_terms["lift"]
	var drag_force: Vector3 = force_terms["drag"]
	var side_force: Vector3 = force_terms["side"]
	var gravity_force: Vector3 = force_terms["gravity"]
	var damping_force: Vector3 = force_terms["damping"]
	var net_force := (
		thrust_force +
		lift_force +
		side_force +
		drag_force +
		gravity_force +
		damping_force
	)

	return {
		"speed": speed,
		"thrust_along_velocity": thrust_force.dot(velocity_dir),
		"drag_along_velocity": drag_force.dot(velocity_dir),
		"gravity_along_velocity": gravity_force.dot(velocity_dir),
		"damping_along_velocity": damping_force.dot(velocity_dir),
		"net_along_velocity": net_force.dot(velocity_dir),
	}
