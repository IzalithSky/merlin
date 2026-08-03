class_name GroundUnit
extends StaticBody3D

const BULLET_SCENE := preload("res://scenes/bullet.tscn")
const MISSILE_SCENE := preload("res://scenes/missile.tscn")

enum UnitType { AA, SAM }

@export var unit_type: UnitType = UnitType.AA
@export var team_id: int = 2
@export var fire_range: float = 1500.0
@export var scan_interval: float = 0.5

@export var aa_burst_size: int = 8
@export var aa_shot_interval: float = 0.07
@export var aa_burst_cooldown: float = 2.0
@export var aa_bullet_speed: float = 900.0
@export var aa_bullet_damage: float = 25.0
@export var aa_spread_deg: float = 0.5

@export var sam_lock_time: float = 2.5
@export var sam_fire_cooldown: float = 6.0

var ground_unit_id: int = -1
var is_shot_down: bool = false
var is_local_player: bool = false

var _target: Node3D = null
var _scan_timer: float = 0.0
var _burst_remaining: int = 0
var _shot_timer: float = 0.0
var _cooldown_timer: float = 0.0
var _lock_timer: float = 0.0
var _health: Health = null
var _projectiles: Node = null

static var _id_counter: int = 100


func _ready() -> void:
	ground_unit_id = _id_counter
	_id_counter += 1
	add_to_group("ground_unit")
	set_physics_process(_has_simulation_authority())
	_health = get_node_or_null("Health") as Health
	if _health != null:
		_health.shot_down.connect(_on_shot_down)
	call_deferred("_deferred_init")


func _deferred_init() -> void:
	var tree := get_tree()
	# Wait one physics step so a randomized terrain transform is live in the
	# physics server before the snap raycast samples it; otherwise the unit
	# snaps to the pre-randomization terrain height and ends up buried.
	if tree != null:
		await tree.physics_frame
		if not is_inside_tree():
			return
	_snap_to_terrain()
	tree = get_tree()
	if tree != null:
		_projectiles = tree.current_scene.find_child("projectiles", true, false)
	_register_with_target_registry()


func _physics_process(delta: float) -> void:
	if is_shot_down or not _has_simulation_authority():
		return
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = scan_interval
		_target = _find_target()
	if _target == null or not is_instance_valid(_target):
		_target = null
		_lock_timer = 0.0
		return
	if unit_type == UnitType.AA:
		_update_aa(delta)
	else:
		_update_sam(delta)


func _update_aa(delta: float) -> void:
	_cooldown_timer -= delta
	_shot_timer -= delta
	if _cooldown_timer > 0.0:
		return
	if _burst_remaining <= 0 and _is_in_fire_envelope():
		_burst_remaining = aa_burst_size
		_shot_timer = 0.0
	if _burst_remaining > 0 and _shot_timer <= 0.0:
		_fire_aa_shot()
		_burst_remaining -= 1
		_shot_timer = aa_shot_interval
		if _burst_remaining <= 0:
			_cooldown_timer = aa_burst_cooldown


func _update_sam(delta: float) -> void:
	_cooldown_timer -= delta
	if _cooldown_timer > 0.0:
		_lock_timer = 0.0
		return
	if _is_in_fire_envelope():
		_lock_timer += delta
		if _lock_timer >= sam_lock_time:
			_fire_sam()
			_cooldown_timer = sam_fire_cooldown
			_lock_timer = 0.0
	else:
		_lock_timer = 0.0


func _is_in_fire_envelope() -> bool:
	if _target == null or not is_instance_valid(_target):
		return false
	var dist := global_position.distance_to(_target.global_position)
	if dist > fire_range:
		return false
	return _target.global_position.y > global_position.y + 20.0


func _fire_aa_shot() -> void:
	if not _has_simulation_authority() or _projectiles == null or not is_instance_valid(_projectiles):
		return
	var target_vel := _get_target_velocity(_target)
	var rel_pos := _target.global_position - global_position
	var aim_dir := Autocannon._compute_intercept_direction(
		rel_pos,
		target_vel,
		aa_bullet_speed
	)
	if aa_spread_deg > 0.0:
		var spread := deg_to_rad(aa_spread_deg)
		var rand_axis := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)).normalized()
		if rand_axis.length_squared() > 0.0001:
			aim_dir = aim_dir.rotated(rand_axis, randf_range(-spread, spread))
	var bullet := BULLET_SCENE.instantiate() as Bullet
	bullet.shooter = self
	bullet.damage = aa_bullet_damage
	_projectiles.add_child(bullet)
	bullet.initialize_launch(global_position + Vector3.UP * 3.0, aim_dir * aa_bullet_speed)


func _fire_sam() -> void:
	if not _has_simulation_authority() or _projectiles == null or not is_instance_valid(_projectiles):
		return
	var launch_pos := global_position + Vector3.UP * 3.0
	var launch_tr := _get_launch_transform(launch_pos, _target.global_position)
	var missile := MISSILE_SCENE.instantiate()
	missile.global_transform = launch_tr
	missile.target = _target
	missile.host = self
	_projectiles.add_child(missile)


func _get_launch_transform(launch_pos: Vector3, target_pos: Vector3) -> Transform3D:
	var to_target := (target_pos - launch_pos).normalized()
	var up_ref := Vector3.RIGHT if absf(to_target.dot(Vector3.UP)) > 0.95 else Vector3.UP
	return Transform3D(Basis.IDENTITY, launch_pos).looking_at(target_pos, up_ref)


func _find_target() -> Node3D:
	var best: Node3D = null
	var best_dist_sq := fire_range * fire_range
	for node in get_tree().get_nodes_in_group("plane_character"):
		if not is_instance_valid(node):
			continue
		if not _is_hostile(node):
			continue
		if node.is_shot_down:
			continue
		var dist_sq := global_position.distance_squared_to(node.global_position)
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best = node
	return best


func _is_hostile(node: Node3D) -> bool:
	if not ("team_id" in node):
		return true
	var other_team := int(node.get("team_id"))
	if team_id <= 0 or other_team <= 0:
		return true
	return other_team != team_id


func _get_target_velocity(target: Node3D) -> Vector3:
	if target.is_in_group("plane_character"):
		return target.get_replicated_velocity()
	if target is RigidBody3D:
		return (target as RigidBody3D).linear_velocity
	return Vector3.ZERO


func take_damage(amount: float) -> void:
	if is_shot_down or not _has_simulation_authority():
		return
	if _health != null:
		_health.take_damage(amount)


func _on_shot_down() -> void:
	is_shot_down = true
	_target = null
	var lockable := get_node_or_null("LockableTarget")
	if lockable == null:
		return
	var registry := _find_target_registry()
	if registry != null:
		registry.unregister_target(lockable)


func _snap_to_terrain() -> void:
	var space_state := get_world_3d().direct_space_state
	var ray_start := global_position + Vector3.UP * 5000.0
	var ray_end := global_position + Vector3.DOWN * 5000.0
	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end, 1)
	query.exclude = [get_rid()]
	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		global_position.y = float(result["position"].y)


func _register_with_target_registry() -> void:
	var lockable := get_node_or_null("LockableTarget")
	if lockable == null:
		return
	var registry := _find_target_registry()
	if registry != null:
		registry.register_target(lockable)


func _find_target_registry() -> TargetRegistry:
	var spawner_nodes := get_tree().get_nodes_in_group("world_character_spawner")
	if not spawner_nodes.is_empty():
		var spawner = spawner_nodes[0]
		if spawner != null and is_instance_valid(spawner):
			return spawner.get_target_registry() as TargetRegistry
	return get_tree().current_scene.find_child("TargetRegistry", true, false) as TargetRegistry


func _has_simulation_authority() -> bool:
	return multiplayer.multiplayer_peer == null or multiplayer.is_server()
