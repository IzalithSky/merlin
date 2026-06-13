class_name ProjectileNetReplicator
extends Node

const MISSILE_SCENE := preload("res://scenes/missile.tscn")
const BULLET_SCENE := preload("res://scenes/bullet.tscn")
const EXPLOSION_SCENE := preload("res://scenes/explosion.tscn")
const AUTOCANNON_SCRIPT := preload("res://scripts/autocannon.gd")

var _spawner
var _projectiles: Node3D
var _next_missile_id: int = 0
var _active_missiles: Dictionary = {}
var _remote_missiles: Dictionary = {}
var _next_bullet_id: int = 0
var _active_bullets: Dictionary = {}
var _active_bullet_visuals: Dictionary = {}
var _gun_cooldowns: Dictionary = {}
var _missile_cooldowns: Dictionary = {}


func configure(spawner, projectiles: Node3D) -> void:
	_spawner = spawner
	_projectiles = projectiles
	if _projectiles == null:
		return

	var projectile_entered_callback := Callable(self, "_on_projectile_entered")
	if not _projectiles.child_entered_tree.is_connected(projectile_entered_callback):
		_projectiles.child_entered_tree.connect(projectile_entered_callback)


func get_projectiles_container() -> Node3D:
	return _projectiles


func fire_missile(firing_plane: Node3D, locked_target: Node3D) -> void:
	_server_fire_missile(firing_plane, locked_target)


func fire_autocannon(plane: Node3D, firing_peer_id: int, target_peer_id: int = -1) -> void:
	_server_fire_autocannon(plane, firing_peer_id, target_peer_id)


func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	for peer_id in _gun_cooldowns.keys():
		var cooldown := maxf(float(_gun_cooldowns[peer_id]) - delta, 0.0)
		if cooldown <= 0.0:
			_gun_cooldowns.erase(peer_id)
		else:
			_gun_cooldowns[peer_id] = cooldown

	for peer_id in _missile_cooldowns.keys():
		var cooldown := maxf(float(_missile_cooldowns[peer_id]) - delta, 0.0)
		if cooldown <= 0.0:
			_missile_cooldowns.erase(peer_id)
		else:
			_missile_cooldowns[peer_id] = cooldown


func _on_projectile_entered(node: Node) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	var missile := node as Missile
	if missile == null:
		return

	var missile_id := _next_missile_id
	_next_missile_id += 1
	_active_missiles[missile_id] = missile
	var velocity := missile.linear_velocity
	var target_ref := _get_target_ref(missile.target)

	missile.died.connect(
		func(exploded: bool, pos: Vector3) -> void: _on_missile_died(missile_id, exploded, pos)
	)

	for peer_id in multiplayer.get_peers():
		if _spawner.is_peer_world_ready(peer_id):
			cl_spawn_missile.rpc_id(peer_id, missile_id, missile.global_transform, velocity, target_ref.x, target_ref.y)


func _on_missile_died(missile_id: int, exploded: bool, pos: Vector3) -> void:
	_active_missiles.erase(missile_id)
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	for peer_id in multiplayer.get_peers():
		if _spawner.is_peer_world_ready(peer_id):
			cl_despawn_missile.rpc_id(peer_id, missile_id, exploded, pos)


func _server_fire_missile(firing_plane: Node3D, locked_target: Node3D) -> void:
	var missile := MISSILE_SCENE.instantiate() as Missile
	var launcher = firing_plane.get_missile_launcher_component()
	if launcher != null:
		missile.global_transform = launcher.get_and_advance_launch_transform(firing_plane)
	else:
		missile.global_transform = firing_plane.global_transform
	missile.target = locked_target
	missile.host = firing_plane
	missile.linear_velocity = firing_plane.linear_velocity
	_projectiles.add_child(missile)
	missile.add_collision_exception_with(firing_plane)


func _server_fire_autocannon(plane: Node3D, firing_peer_id: int, target_peer_id: int = -1) -> void:
	var autocannon = plane.get_autocannon_component()
	if autocannon == null or not is_instance_valid(autocannon):
		return

	var desired_target := _resolve_autocannon_target(plane, target_peer_id)
	var aim_direction := AUTOCANNON_SCRIPT.compute_aim_direction(
		plane,
		desired_target,
		autocannon.bullet_speed,
		autocannon.lead_cone_half_angle_deg
	)

	var bullet := BULLET_SCENE.instantiate()
	bullet.shooter = plane
	bullet.damage = autocannon.damage
	_projectiles.add_child(bullet)
	var launch_velocity: Vector3 = aim_direction * autocannon.bullet_speed + plane.linear_velocity
	bullet.initialize_launch(autocannon.get_and_advance_launch_position(plane), launch_velocity)

	var bullet_id := _next_bullet_id
	_next_bullet_id += 1
	_active_bullets[bullet_id] = bullet
	_gun_cooldowns[firing_peer_id] = autocannon.fire_cooldown

	bullet.died.connect(func(hit: bool, pos: Vector3) -> void: _on_bullet_died(hit, pos, bullet_id))

	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	for peer_id in multiplayer.get_peers():
		if _spawner.is_peer_world_ready(peer_id):
			cl_spawn_bullet.rpc_id(peer_id, bullet_id, bullet.global_position, bullet.linear_velocity)


func _resolve_autocannon_target(plane: Node3D, target_peer_id: int) -> Node3D:
	if target_peer_id < 0:
		return null

	var target: Node3D = _spawner.get_character(target_peer_id)
	if target == null or not is_instance_valid(target):
		return null
	if target.is_shot_down:
		return null

	var weapon_lock = plane.get_weapon_lock_component()
	if weapon_lock == null or not is_instance_valid(weapon_lock):
		return null
	if not weapon_lock.is_target_in_envelope(target):
		return null

	return target


func _resolve_missile_target(plane: Node3D, target_kind: int, target_id: int) -> Node3D:
	if target_kind < 0 or target_id < 0:
		return null

	var registry = _spawner.get_target_registry()
	if registry == null or not is_instance_valid(registry):
		return null

	var lockable_target = registry.resolve_target(target_kind, target_id)
	if lockable_target == null or not is_instance_valid(lockable_target):
		return null
	if not lockable_target.is_lockable():
		return null

	var target: Node3D = lockable_target.get_host_node()
	if target == null or not is_instance_valid(target):
		return null

	var weapon_lock = plane.get_weapon_lock_component()
	if weapon_lock == null or not is_instance_valid(weapon_lock):
		return null
	if not weapon_lock.is_target_lockable(target):
		return null
	if not weapon_lock.is_target_in_envelope(target):
		return null

	return target


func _on_bullet_died(_hit: bool, pos: Vector3, bullet_id: int) -> void:
	_active_bullets.erase(bullet_id)
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	for peer_id in multiplayer.get_peers():
		if _spawner.is_peer_world_ready(peer_id):
			cl_despawn_bullet.rpc_id(peer_id, bullet_id, pos)


@rpc("any_peer", "reliable")
func sv_request_fire_missile(firing_peer_id: int, target_kind: int, target_id: int) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != firing_peer_id:
		return

	var firing_plane: Node3D = _spawner.get_character(firing_peer_id)
	if firing_plane == null or not is_instance_valid(firing_plane):
		return
	if firing_plane.is_shot_down:
		return

	var cooldown := float(_missile_cooldowns.get(firing_peer_id, 0.0))
	if cooldown > 0.0:
		return

	var locked_target := _resolve_missile_target(firing_plane, target_kind, target_id)
	var launcher = firing_plane.get_missile_launcher_component()
	if launcher != null and is_instance_valid(launcher):
		_missile_cooldowns[firing_peer_id] = launcher.fire_cooldown
	_server_fire_missile(firing_plane, locked_target)


@rpc("any_peer", "reliable")
func sv_request_fire_autocannon(firing_peer_id: int, target_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != firing_peer_id:
		return

	var plane: Node3D = _spawner.get_character(firing_peer_id)
	if plane == null or not is_instance_valid(plane):
		return
	if plane.is_shot_down:
		return

	var cooldown := float(_gun_cooldowns.get(firing_peer_id, 0.0))
	if cooldown > 0.0:
		return

	_server_fire_autocannon(plane, firing_peer_id, target_peer_id)


@rpc("authority", "reliable")
func cl_spawn_missile(missile_id: int, transform_value: Transform3D, velocity: Vector3, target_kind: int, target_id: int) -> void:
	if multiplayer.is_server():
		return

	var missile := MISSILE_SCENE.instantiate() as Missile
	_projectiles.add_child(missile)
	missile.init_replica(transform_value, velocity, _resolve_remote_missile_target(target_kind, target_id))
	_remote_missiles[missile_id] = missile


@rpc("authority", "call_remote", "reliable", 0)
func cl_spawn_bullet(bullet_id: int, pos: Vector3, velocity: Vector3) -> void:
	if multiplayer.is_server():
		return

	var bullet := BULLET_SCENE.instantiate() as Bullet
	_projectiles.add_child(bullet)
	bullet.init_replica(pos, velocity)
	_active_bullet_visuals[bullet_id] = bullet


@rpc("authority", "reliable")
func cl_despawn_missile(missile_id: int, exploded: bool, pos: Vector3) -> void:
	if multiplayer.is_server():
		return

	var visual = _remote_missiles.get(missile_id)
	if visual != null and is_instance_valid(visual):
		if exploded:
			var explosion := EXPLOSION_SCENE.instantiate() as Node3D
			_projectiles.add_child(explosion)
			explosion.global_position = pos
		visual.despawn(pos)
	_remote_missiles.erase(missile_id)


func _resolve_remote_missile_target(target_kind: int, target_id: int) -> Node3D:
	if target_kind < 0 or target_id < 0:
		return null
	var registry = _spawner.get_target_registry()
	if registry == null or not is_instance_valid(registry):
		return null
	return registry.resolve_target_host(target_kind, target_id)


func _get_target_ref(target: Node3D) -> Vector2i:
	var lockable_target = _get_lockable_target(target)
	if lockable_target == null:
		return Vector2i(-1, -1)
	return Vector2i(lockable_target.get_target_kind(), lockable_target.get_target_id())


func _get_lockable_target(target: Node3D):
	if target == null or not is_instance_valid(target):
		return null
	return target.get_node_or_null("LockableTarget")


@rpc("authority", "call_remote", "reliable", 0)
func cl_despawn_bullet(bullet_id: int, pos: Vector3) -> void:
	if multiplayer.is_server():
		return

	var visual = _active_bullet_visuals.get(bullet_id)
	if visual != null and is_instance_valid(visual):
		visual.despawn(pos)
	_active_bullet_visuals.erase(bullet_id)
