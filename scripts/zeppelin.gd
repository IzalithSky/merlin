class_name Zeppelin
extends RigidBody3D

const FLAME_TRAIL_SCENE := preload("res://scenes/flame_trail.tscn")
const POINT_A_UNSET := Vector3(100000000000000000000.0, 100000000000000000000.0, 100000000000000000000.0)

enum FlightMode { HOVER, ONE_WAY, PATROL }

@export var flight_mode: FlightMode = FlightMode.ONE_WAY
@export var point_a: Vector3 = POINT_A_UNSET
@export var point_b: Vector3 = Vector3(5000, 0, 0)
@export var speed: float = 30.0
@export var team_id: int = 0
@export var shot_down_spin_min_deg: float = 20.0
@export var shot_down_spin_max_deg: float = 80.0

var is_shot_down: bool = false
var zeppelin_id: int = -1

static var _id_counter: int = 200

var _flight_direction := Vector3.FORWARD
var _flight_velocity := Vector3.ZERO
var _flight_point_a := Vector3.ZERO
var _flight_target := Vector3.ZERO
var _health: Health = null
var _lockable: Node = null
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	zeppelin_id = _id_counter
	_id_counter += 1
	add_to_group("zeppelin")
	_rng.randomize()

	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	gravity_scale = 0.0
	linear_damp = 0.3
	angular_damp = 1.5

	_health = get_node_or_null("Health") as Health
	_lockable = get_node_or_null("LockableTarget")
	if _health != null:
		_health.shot_down.connect(_on_shot_down)

	global_position = _resolve_start_position()
	_flight_point_a = global_position
	_configure_flight()

	call_deferred("_register_with_target_registry")


func _physics_process(delta: float) -> void:
	if is_shot_down:
		return
	if flight_mode == FlightMode.HOVER:
		if _lockable != null:
			_lockable.velocity = Vector3.ZERO
		return
	global_position += _flight_velocity * delta
	if _lockable != null:
		_lockable.velocity = _flight_velocity
	if not _has_simulation_authority():
		return
	if (_flight_target - global_position).dot(_flight_direction) > 0.0:
		return
	match flight_mode:
		FlightMode.ONE_WAY:
			_unregister_from_target_registry()
			queue_free()
		FlightMode.PATROL:
			global_position = _flight_target
			_set_flight_target(_flight_point_a if _flight_target == point_b else point_b)


func take_damage(amount: float) -> void:
	if is_shot_down or _health == null or not _has_simulation_authority():
		return
	_health.take_damage(amount)


func _on_shot_down() -> void:
	if is_shot_down:
		return
	is_shot_down = true

	freeze = false
	gravity_scale = 1.0
	linear_velocity = _flight_velocity

	var spin_axis := (
		global_transform.basis.z
		+ Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.5, 0.5), _rng.randf_range(-1.0, 1.0))
	).normalized()
	var spin_deg := _rng.randf_range(shot_down_spin_min_deg, shot_down_spin_max_deg)
	if _rng.randf() < 0.5:
		spin_deg *= -1.0
	angular_velocity = spin_axis * deg_to_rad(spin_deg)

	var flame := FLAME_TRAIL_SCENE.instantiate() as Node3D
	add_child(flame)

	_unregister_from_target_registry()


func _register_with_target_registry() -> void:
	if _lockable == null:
		return
	var registry := _find_target_registry()
	if registry != null:
		registry.register_target(_lockable)


func _unregister_from_target_registry() -> void:
	if _lockable == null:
		return
	var registry := _find_target_registry()
	if registry != null:
		registry.unregister_target(_lockable)


func _find_target_registry() -> TargetRegistry:
	var spawner_nodes := get_tree().get_nodes_in_group("world_character_spawner")
	if not spawner_nodes.is_empty():
		var spawner = spawner_nodes[0]
		if spawner != null and is_instance_valid(spawner):
			return spawner.get_target_registry() as TargetRegistry
	return get_tree().current_scene.find_child("TargetRegistry", true, false) as TargetRegistry


func _has_simulation_authority() -> bool:
	return multiplayer.multiplayer_peer == null or multiplayer.is_server()


func _resolve_start_position() -> Vector3:
	if point_a != POINT_A_UNSET:
		return point_a
	return global_position


func _configure_flight() -> void:
	if flight_mode == FlightMode.HOVER:
		_flight_direction = -global_transform.basis.z.normalized()
		_flight_velocity = Vector3.ZERO
		if _lockable != null:
			_lockable.velocity = Vector3.ZERO
		return
	_set_flight_target(point_b)


func _set_flight_target(target: Vector3) -> void:
	_flight_target = target
	var to_target := _flight_target - global_position
	if to_target.length_squared() > 0.001:
		_flight_direction = to_target.normalized()
		_orient_to_direction(_flight_direction)
		_flight_velocity = _flight_direction * maxf(speed, 0.0)
		return
	_flight_velocity = Vector3.ZERO


func _orient_to_direction(direction: Vector3) -> void:
	var up_ref := Vector3.RIGHT if absf(direction.dot(Vector3.UP)) > 0.95 else Vector3.UP
	global_transform = global_transform.looking_at(global_position + direction, up_ref)
