extends RigidBody3D

@export var thrust: float = 12_000.0
@export var drag_coeff: float = 0.1
@export var lateral_force: float = 60_000.0
@export var torque_strength: float = 10.0
@export var max_ang_vel_deg: float = 200.0
@export var max_lifetime: float = 15.0
@export var proximity_radius: float = 15.0
@export var proximity_fuse_delay: float = 0.4
@export var explosion_radius: float = 50.0
@export var explosion_min_damage: float = 10.0
@export var explosion_max_damage: float = 80.0
@export var explosion_collision_mask: int = 1
@export var explosion_scene: PackedScene
@export var trail_lifespan: float = 2.0
@export var trail_ttl_after_death: float = 4.0
@export var target_loss_grace_period: float = 1.5
@export var explode_on_timeout: bool = true
@export var seeker_cone_half_angle_deg: float = 60.0

const TRAIL_SCENE := preload("res://scenes/wing_trail.tscn")

signal died(exploded: bool, position: Vector3)

var target: Node3D = null
var host: RigidBody3D = null

var _time_since_launch: float = 0.0
var _time_since_target_lost: float = 0.0
var _had_target: bool = false
var _exploded: bool = false
var _previous_deviation: Vector3 = Vector3.ZERO
var _trail: Node = null


func _ready() -> void:
	_had_target = target != null and is_instance_valid(target)
	body_entered.connect(_on_body_entered)
	_spawn_trail()


func _physics_process(delta: float) -> void:
	_time_since_launch += delta

	apply_central_force(-global_transform.basis.z * thrust)
	_apply_drag()
	_apply_stabilisation()
	_apply_guidance(delta)

	if _time_since_launch >= max_lifetime:
		if explode_on_timeout:
			_spawn_explosion()
		_die()
		return

	var max_av := deg_to_rad(max_ang_vel_deg)
	if angular_velocity.length_squared() > max_av * max_av:
		angular_velocity = angular_velocity.normalized() * max_av

	if _trail != null and is_instance_valid(_trail):
		_trail.global_position = global_position


func _apply_drag() -> void:
	apply_central_force(-linear_velocity * drag_coeff * linear_velocity.length())


func _apply_stabilisation() -> void:
	var av_len := angular_velocity.length()
	if av_len > 1e-4:
		apply_torque(-angular_velocity.normalized() * minf(av_len, torque_strength))


func _apply_guidance(delta: float) -> void:
	if _time_since_launch < proximity_fuse_delay:
		return

	if target == null or not is_instance_valid(target):
		if _had_target:
			_time_since_target_lost += delta
			if _time_since_target_lost >= target_loss_grace_period:
				if explode_on_timeout:
					_spawn_explosion()
				_die()
		return

	_had_target = true
	_time_since_target_lost = 0.0
	var deviation := target.global_position - global_position
	var dist := deviation.length()

	var fwd := -global_transform.basis.z
	if fwd.dot(deviation / dist) < cos(deg_to_rad(seeker_cone_half_angle_deg)):
		target = null
		return

	if dist < proximity_radius:
		_spawn_explosion()
		_die()
		return

	var variation := deviation - _previous_deviation
	_previous_deviation = deviation
	var steer_dir := (deviation + variation).normalized()

	var vel_dir := linear_velocity.normalized()
	var lateral := steer_dir - vel_dir * vel_dir.dot(steer_dir)
	if lateral.length_squared() > 1e-8:
		apply_central_force(lateral * lateral_force)

	var angle := fwd.angle_to(steer_dir)

	if angle > 1e-3:
		var axis := fwd.cross(steer_dir)
		if axis.length_squared() > 1e-6:
			axis = axis.normalized()
			var max_turn := deg_to_rad(max_ang_vel_deg) * delta
			var turn_angle := minf(angle, max_turn)
			apply_torque(axis * torque_strength * (turn_angle / maxf(delta, 1e-4)))


func _on_body_entered(body: Node) -> void:
	if body == host:
		return
	_spawn_explosion()
	_die()


func _die() -> void:
	var death_pos := global_position
	if _trail != null and is_instance_valid(_trail):
		if "trail_enabled" in _trail:
			_trail.set("trail_enabled", false)
		if "permanent" in _trail:
			_trail.set("permanent", false)
		if "node_ttl" in _trail:
			_trail.set("node_ttl", trail_ttl_after_death)
		_trail = null
	died.emit(_exploded, death_pos)
	queue_free()


func _spawn_explosion() -> void:
	_exploded = true
	if explosion_scene != null:
		var e := explosion_scene.instantiate() as Node3D
		get_tree().current_scene.add_child(e)
		e.global_position = global_position

	var shape := SphereShape3D.new()
	shape.radius = explosion_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = global_transform
	query.collision_mask = explosion_collision_mask
	query.collide_with_bodies = true

	var space_state := get_world_3d().direct_space_state
	var results := space_state.intersect_shape(query, 32)

	for result in results:
		var collider := result["collider"] as Node
		if collider == null or collider == host:
			continue
		var receiver := _find_damage_receiver(collider)
		if receiver != null and receiver.has_method("take_damage"):
			var dist := global_position.distance_to(collider.global_position)
			var t := clampf(1.0 - dist / explosion_radius, 0.0, 1.0)
			var dmg := lerpf(explosion_min_damage, explosion_max_damage, t)
			receiver.call("take_damage", dmg)


func _find_damage_receiver(node: Node) -> Node:
	if node.has_method("take_damage"):
		return node
	for child in node.get_children():
		if child.has_method("take_damage"):
			return child
	return null


func _spawn_trail() -> void:
	var trail := TRAIL_SCENE.instantiate()
	if "permanent" in trail:
		trail.set("permanent", false)
	if "trail_enabled" in trail:
		trail.set("trail_enabled", true)
	if "start_color" in trail:
		trail.set("start_color", Color(1.0, 0.85, 0.0, 0.85))
	if "end_color" in trail:
		trail.set("end_color", Color(1.0, 0.85, 0.0, 0.0))
	if "from_width" in trail:
		trail.set("from_width", 0.8)
	if "to_width" in trail:
		trail.set("to_width", 0.15)
	if "lifespan" in trail:
		trail.set("lifespan", trail_lifespan)
	get_tree().current_scene.add_child(trail)
	trail.global_position = global_position
	_trail = trail
