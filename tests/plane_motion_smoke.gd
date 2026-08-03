extends SceneTree

const PLANE_SCENE := preload("res://scenes/plane_character.tscn")
const PLANE_MOTION_STATE := preload("res://scripts/plane_motion_state.gd")
const BULLET_SCENE := preload("res://scenes/bullet.tscn")
const MISSILE_SCENE := preload("res://scenes/missile.tscn")

var _failed := false
var _test_root: Node3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_setup_test_root()
	await _test_motion_state_roundtrip()
	await _test_force_gravity_and_damping()
	await _test_torque_integration()
	await _test_wall_collision_clips_velocity()
	await _test_projectiles_do_not_block_plane_motion()
	await _test_projectile_hits_damage_without_moving_plane()

	if not _failed:
		print("plane_motion_smoke_ok")
		_test_root.free()
		quit(0)


func _setup_test_root() -> void:
	_test_root = Node3D.new()
	_test_root.name = "PlaneMotionSmokeRoot"
	var projectiles := Node3D.new()
	projectiles.name = "projectiles"
	_test_root.add_child(projectiles)
	get_root().add_child(_test_root)
	current_scene = _test_root


func _test_motion_state_roundtrip() -> void:
	var plane := await _spawn_test_plane()
	plane.global_transform = Transform3D(Basis.from_euler(Vector3(0.1, 0.2, 0.3)), Vector3(1.0, 2.0, 3.0))
	plane.linear_velocity = Vector3(4.0, 5.0, 6.0)
	plane.angular_velocity = Vector3(0.4, 0.5, 0.6)
	plane.is_shot_down = true
	plane.set_last_ground_impact_time(12.5)

	var state = plane.get_motion_state()
	plane.global_position = Vector3(-10.0, -20.0, -30.0)
	plane.linear_velocity = Vector3.ZERO
	plane.angular_velocity = Vector3.ZERO
	plane.is_shot_down = false
	plane.set_last_ground_impact_time(-INF)
	plane.restore_motion_state(state)

	_assert(_approx_vec3(plane.global_position, Vector3(1.0, 2.0, 3.0)), "state restore position failed")
	_assert(_approx_quat(plane.global_transform.basis.get_rotation_quaternion(), state.transform.basis.get_rotation_quaternion()), "state restore rotation failed")
	_assert(_approx_vec3(plane.linear_velocity, Vector3(4.0, 5.0, 6.0)), "state restore linear velocity failed")
	_assert(_approx_vec3(plane.angular_velocity, Vector3(0.4, 0.5, 0.6)), "state restore angular velocity failed")
	_assert(plane.is_shot_down, "state restore shot-down flag failed")
	_assert(_approx(plane.get_last_ground_impact_time(), 12.5), "state restore timer failed")
	plane.free()


func _test_force_gravity_and_damping() -> void:
	var plane := await _spawn_test_plane()
	plane.mass = 10.0
	plane.gravity_scale = 0.0
	plane.add_central_force(Vector3(20.0, 0.0, 0.0))
	plane.integrate_motion_step(0.5)
	_assert(_approx_vec3(plane.linear_velocity, Vector3(1.0, 0.0, 0.0)), "force integration velocity failed")
	_assert(_approx_vec3(plane.global_position, Vector3(0.5, 0.0, 0.0)), "force integration position failed")

	plane.global_position = Vector3.ZERO
	plane.linear_velocity = Vector3(10.0, 0.0, 0.0)
	plane.gravity_scale = 1.0
	plane.linear_damp = 0.5
	plane.integrate_motion_step(1.0)
	var gravity_direction: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector")
	var gravity_magnitude: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	var expected_velocity := (Vector3(10.0, 0.0, 0.0) + gravity_direction * gravity_magnitude) * 0.5
	_assert(_approx_vec3(plane.linear_velocity, expected_velocity), "gravity/damping velocity failed")
	plane.free()


func _test_torque_integration() -> void:
	var plane := await _spawn_test_plane()
	plane.gravity_scale = 0.0
	plane.angular_inertia = Vector3(2.0, 4.0, 8.0)
	plane.add_torque(Vector3(4.0, 0.0, 0.0))
	plane.integrate_motion_step(0.5)
	_assert(_approx_vec3(plane.angular_velocity, Vector3(1.0, 0.0, 0.0)), "torque integration angular velocity failed")
	var expected_rotation := Quaternion(Vector3.RIGHT, 0.5)
	_assert(_approx_quat(plane.global_transform.basis.get_rotation_quaternion(), expected_rotation), "torque integration rotation failed")
	plane.free()


func _test_wall_collision_clips_velocity() -> void:
	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(1.0, 20.0, 20.0)
	wall_shape.shape = wall_box
	wall.add_child(wall_shape)
	_test_root.add_child(wall)
	wall.global_position = Vector3.ZERO

	var plane := await _spawn_test_plane()
	plane.gravity_scale = 0.0
	plane.global_position = Vector3(-8.0, 0.0, 0.0)
	plane.linear_velocity = Vector3(20.0, 0.0, -5.0)
	await physics_frame
	plane.integrate_motion_step(0.5)

	_assert(absf(plane.linear_velocity.x) <= 0.05, "wall collision should clip inward velocity")
	_assert(_approx(plane.linear_velocity.z, -5.0), "wall collision should preserve tangent velocity")
	_assert(plane.global_position.x <= -5.49, "wall collision should not penetrate")
	plane.free()
	wall.free()


func _test_projectiles_do_not_block_plane_motion() -> void:
	var projectile_body := RigidBody3D.new()
	var projectile_shape := CollisionShape3D.new()
	var projectile_sphere := SphereShape3D.new()
	projectile_sphere.radius = 2.0
	projectile_shape.shape = projectile_sphere
	projectile_body.add_child(projectile_shape)
	projectile_body.collision_layer = 2
	projectile_body.collision_mask = 1
	projectile_body.freeze = true
	_test_root.add_child(projectile_body)
	projectile_body.global_position = Vector3.ZERO

	var plane := await _spawn_test_plane()
	plane.gravity_scale = 0.0
	plane.global_position = Vector3(-8.0, 0.0, 0.0)
	plane.linear_velocity = Vector3(20.0, 0.0, 0.0)
	await physics_frame
	plane.integrate_motion_step(0.5)

	_assert(_approx_vec3(plane.linear_velocity, Vector3(20.0, 0.0, 0.0)), "projectile body should not clip plane velocity")
	_assert(plane.global_position.x > 1.9, "projectile body should not block plane sweep")
	plane.free()
	projectile_body.free()


func _test_projectile_hits_damage_without_moving_plane() -> void:
	var bullet_result := await _run_projectile_hit_probe(BULLET_SCENE, Vector3(1000.0, 0.0, 0.0), 10)
	_assert(_approx(float(bullet_result["hp_after"]), 75.0), "bullet hit should apply direct damage")
	_assert(_approx_vec3(Vector3(bullet_result["plane_velocity"]), Vector3.ZERO), "bullet hit should not move plane")

	var missile_result := await _run_projectile_hit_probe(MISSILE_SCENE, Vector3(250.0, 0.0, 0.0), 20)
	_assert(float(missile_result["hp_after"]) < 100.0, "missile hit should apply explosion damage")
	_assert(_approx_vec3(Vector3(missile_result["plane_velocity"]), Vector3.ZERO), "missile hit should not move plane")


func _run_projectile_hit_probe(projectile_scene: PackedScene, launch_velocity: Vector3, frame_count: int) -> Dictionary:
	var plane := await _spawn_test_plane()
	plane.gravity_scale = 0.0
	plane.global_position = Vector3.ZERO
	plane.linear_velocity = Vector3.ZERO
	plane.angular_velocity = Vector3.ZERO
	var health = plane.get_health_component()
	var projectile = projectile_scene.instantiate()
	if projectile is Bullet:
		projectile.shooter = null
		projectile.damage = 25.0
	elif projectile is Missile:
		projectile.host = null
		projectile.target = null
		projectile.thrust = 0.0
		projectile.explosion_scene = null
	_test_root.add_child(projectile)
	if projectile.has_method("initialize_launch"):
		projectile.call("initialize_launch", Vector3(-30.0, 0.0, 0.0), launch_velocity)
	else:
		projectile.global_position = Vector3(-30.0, 0.0, 0.0)
		projectile.linear_velocity = launch_velocity

	for _frame_index in range(frame_count):
		await physics_frame

	var result := {
		"hp_after": float(health.current_hp),
		"plane_velocity": plane.linear_velocity,
	}
	if is_instance_valid(projectile):
		projectile.queue_free()
	plane.free()
	return result


func _spawn_test_plane() -> PlaneCharacter:
	var plane := PLANE_SCENE.instantiate() as PlaneCharacter
	plane.sustain_turn_limiter_enabled = false
	plane.debug_force_vectors_enabled = false
	plane.configure(1, true)
	_test_root.add_child(plane)
	await process_frame
	plane.set_physics_process(false)
	plane.global_position = Vector3.ZERO
	plane.global_basis = Basis.IDENTITY
	plane.linear_velocity = Vector3.ZERO
	plane.angular_velocity = Vector3.ZERO
	plane.gravity_scale = 0.0
	plane.linear_damp = 0.0
	plane.angular_damp = 0.0
	plane.clear_motion_accumulators()
	return plane


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error(message)
	quit(1)


func _approx(value: float, expected: float) -> bool:
	return absf(value - expected) <= 0.001


func _approx_vec3(value: Vector3, expected: Vector3) -> bool:
	return value.distance_to(expected) <= 0.001


func _approx_quat(value: Quaternion, expected: Quaternion) -> bool:
	return value.normalized().angle_to(expected.normalized()) <= 0.001
