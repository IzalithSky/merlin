class_name Autocannon
extends Node

const BULLET_SCENE := preload("res://scenes/bullet.tscn")

@export var bullet_speed: float = 1000.0
@export var fire_cooldown: float = 0.125
@export var lead_cone_half_angle_deg: float = 8.0
@export var damage: float = 25.0
@export var launch_lateral_offset: float = 0.0
@export var launch_vertical_offset: float = 0.0
@export var launch_forward_offset: float = 6.0

var _cooldown_remaining: float = 0.0
var _projectiles_container: Node = null
var _projectile_net: Node = null


func _ready() -> void:
	_projectile_net = _resolve_projectile_net()
	if _projectile_net != null:
		_projectiles_container = _projectile_net.get_projectiles_container()
		if _projectiles_container != null:
			return

	_projectiles_container = get_tree().current_scene.get_node_or_null("projectiles")
	if _projectiles_container == null:
		push_warning("Autocannon: no 'projectiles' node found in scene root; bullets will be added to scene root")
		_projectiles_container = get_tree().current_scene


func _process(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining -= delta

	var plane := get_parent() as Node3D
	if plane == null or not is_instance_valid(plane):
		return
	if not plane.is_in_group("plane_character") or not _is_local_player(plane):
		return
	if plane.is_shot_down:
		return
	if Input.is_action_pressed("fire_autocannon") and _cooldown_remaining <= 0.0:
		_try_fire(plane)


func try_fire() -> void:
	if _cooldown_remaining > 0.0:
		return
	var plane := get_parent()
	if plane == null or not is_instance_valid(plane):
		return
	if plane.is_shot_down:
		return
	_try_fire(plane)


func _try_fire(plane: Node3D) -> void:
	var desired_target: Node3D = null
	var target_peer_id := -1
	var weapon_lock = plane.get_weapon_lock_component()
	if weapon_lock != null and is_instance_valid(weapon_lock):
		desired_target = weapon_lock.get_desired_target()
	if desired_target != null and is_instance_valid(desired_target):
		if desired_target.is_in_group("plane_character"):
			target_peer_id = desired_target.peer_id

	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		var projectile_net = _get_projectile_net()
		if projectile_net != null:
			var spawner = WorldCharacterSpawner.find_in_tree(self)
			if spawner != null:
				spawner.record_net_send("projectile", [multiplayer.get_unique_id(), target_peer_id])
			projectile_net.sv_request_fire_autocannon.rpc_id(1, multiplayer.get_unique_id(), target_peer_id)
		else:
			_fire_local(plane, desired_target)
	elif multiplayer.multiplayer_peer != null and multiplayer.is_server():
		var projectile_net = _get_projectile_net()
		var firing_peer_id = plane.peer_id
		if projectile_net != null:
			projectile_net.fire_autocannon(plane, firing_peer_id, target_peer_id)
		else:
			_fire_local(plane, desired_target)
	else:
		var projectile_net = _get_projectile_net()
		if projectile_net != null:
			projectile_net.fire_autocannon(plane, plane.peer_id, target_peer_id)
		else:
			_fire_local(plane, desired_target)

	_cooldown_remaining = fire_cooldown


func _fire_local(plane: Node3D, desired_target: Node3D) -> void:
	var aim_direction := compute_aim_direction(
		plane,
		desired_target,
		bullet_speed,
		lead_cone_half_angle_deg
	)
	var bullet = BULLET_SCENE.instantiate()
	bullet.shooter = plane
	bullet.damage = damage
	_projectiles_container.add_child(bullet)
	var inherited_velocity := Vector3.ZERO
	if plane is RigidBody3D:
		inherited_velocity = (plane as RigidBody3D).linear_velocity
	var launch_velocity := aim_direction * bullet_speed + inherited_velocity
	bullet.initialize_launch(get_launch_position(plane), launch_velocity)


func get_launch_position(plane: Node3D) -> Vector3:
	var basis := plane.global_transform.basis
	var origin := plane.global_position
	origin += basis.x * launch_lateral_offset
	origin += basis.y * launch_vertical_offset
	origin += -basis.z * launch_forward_offset
	return origin


static func compute_aim_direction(
	plane: Node3D,
	target: Node3D,
	projectile_speed: float,
	lead_cone_limit_deg: float
) -> Vector3:
	var nose := -plane.global_transform.basis.z
	if target == null or not is_instance_valid(target):
		return nose

	var target_velocity := _get_replication_aware_velocity(target)
	var plane_velocity := _get_replication_aware_velocity(plane)

	var relative_position := target.global_position - plane.global_position
	var relative_velocity := target_velocity - plane_velocity
	var raw_direction := _compute_intercept_direction(
		relative_position,
		relative_velocity,
		projectile_speed
	)
	return _clamp_direction_to_cone(nose, raw_direction, lead_cone_limit_deg)


static func _compute_intercept_direction(
	relative_position: Vector3,
	relative_velocity: Vector3,
	projectile_speed: float
) -> Vector3:
	var aim_offset := relative_position
	var speed_sq := projectile_speed * projectile_speed
	var a := speed_sq - relative_velocity.length_squared()
	var b := -2.0 * relative_position.dot(relative_velocity)
	var c := -relative_position.length_squared()
	var discriminant := b * b - 4.0 * a * c

	if absf(a) > 0.0001 and discriminant >= 0.0:
		var sqrt_discriminant := sqrt(discriminant)
		var t0 := (-b - sqrt_discriminant) / (2.0 * a)
		var t1 := (-b + sqrt_discriminant) / (2.0 * a)
		var intercept_time := INF
		if t0 > 0.0:
			intercept_time = t0
		if t1 > 0.0:
			intercept_time = minf(intercept_time, t1)
		if is_finite(intercept_time):
			aim_offset = relative_position + relative_velocity * intercept_time

	if aim_offset.length_squared() <= 0.000001:
		return Vector3.FORWARD
	return aim_offset.normalized()


static func _clamp_direction_to_cone(
	nose: Vector3,
	raw_direction: Vector3,
	lead_cone_limit_deg: float
) -> Vector3:
	var normalized_nose := nose.normalized()
	var normalized_direction := raw_direction.normalized()
	var max_angle := deg_to_rad(lead_cone_limit_deg)
	var angle := normalized_nose.angle_to(normalized_direction)
	if angle <= max_angle:
		return normalized_direction

	var axis := normalized_nose.cross(normalized_direction)
	if axis.length_squared() <= 0.000001:
		return normalized_nose
	return normalized_nose.rotated(axis.normalized(), max_angle).normalized()


static func _get_replication_aware_velocity(body: Node3D) -> Vector3:
	if body == null or not is_instance_valid(body):
		return Vector3.ZERO
	if body.is_in_group("plane_character"):
		return body.get_replicated_velocity()
	if body is RigidBody3D:
		return (body as RigidBody3D).linear_velocity
	var lockable := body.get_node_or_null("LockableTarget") as LockableTarget
	if lockable != null:
		return lockable.velocity
	return Vector3.ZERO


func _is_local_player(plane: Node3D) -> bool:
	return plane.is_local_player


func _get_projectile_net() -> Node:
	if _projectile_net != null and is_instance_valid(_projectile_net):
		return _projectile_net
	_projectile_net = _resolve_projectile_net()
	return _projectile_net


func _resolve_projectile_net() -> Node:
	var world_nodes := get_tree().get_nodes_in_group("world_character_spawner")
	if world_nodes.is_empty():
		return null
	var spawner = world_nodes[0]
	if spawner == null or not is_instance_valid(spawner):
		return null
	return spawner.get_projectile_net()
