class_name Bullet
extends RigidBody3D

const TRAIL_SCENE := preload("res://scenes/wing_trail.tscn")

@export var max_range: float = 2000.0
@export var damage: float = 25.0
@export var trail_lifespan: float = 0.05
@export var trail_ttl_after_death: float = 0.5

signal died(hit: bool, hit_position: Vector3)

var shooter: Node3D = null
var _is_replica := false

var _origin: Vector3 = Vector3.ZERO
var _dead: bool = false
var _trail: VisualTrail3D = null


func init_replica(spawn_position: Vector3, launch_velocity: Vector3) -> void:
	_is_replica = true
	shooter = null
	global_position = spawn_position
	_origin = spawn_position
	linear_velocity = launch_velocity
	collision_layer = 0
	collision_mask = 0
	contact_monitor = false
	max_contacts_reported = 0
	if launch_velocity.length_squared() > 0.000001:
			look_at(global_position + launch_velocity.normalized(), Vector3.UP)


func _ready() -> void:
	add_to_group("bullet")
	_origin = global_position
	if not _is_replica:
		body_entered.connect(_on_body_entered)
	continuous_cd = true
	lock_rotation = true
	if not _is_replica and shooter != null and is_instance_valid(shooter):
		add_collision_exception_with(shooter)
	_spawn_trail()


func initialize_launch(spawn_position: Vector3, launch_velocity: Vector3) -> void:
	global_position = spawn_position
	_origin = spawn_position
	linear_velocity = launch_velocity
	if launch_velocity.length_squared() > 0.000001:
		look_at(global_position + launch_velocity.normalized(), Vector3.UP)
	if _trail != null and is_instance_valid(_trail):
		_trail.global_position = spawn_position


func _physics_process(_delta: float) -> void:
	if linear_velocity.length_squared() > 0.000001:
		look_at(global_position + linear_velocity.normalized(), Vector3.UP)

	if global_position.distance_to(_origin) > max_range:
		if _is_replica:
			return
		_despawn(false)
		return

	if _trail != null and is_instance_valid(_trail):
		_trail.global_position = global_position


func _on_body_entered(body: Node) -> void:
	if _is_replica:
		return
	if body == shooter:
		return
	_deal_damage(body)
	_despawn(true)


func _deal_damage(body: Node) -> void:
	var receiver := _find_damage_receiver(body)
	if receiver != null:
		receiver.call("take_damage", damage)


func _find_damage_receiver(node: Node) -> Node:
	if node.has_method("take_damage"):
		return node
	for child in node.get_children():
		if child.has_method("take_damage"):
			return child
	return null


func _despawn(hit: bool) -> void:
	if _dead:
		return
	_dead = true

	var death_pos := global_position
	_finish_trail()

	died.emit(hit, death_pos)
	queue_free()


func _spawn_trail() -> void:
	var trail := TRAIL_SCENE.instantiate() as VisualTrail3D
	trail.configure(
		true,
		false,
		Color(1.0, 0.4, 0.7, 0.85),
		Color(1.0, 0.4, 0.7, 0.0),
		0.12,
		0.015,
		0.25,
		trail_lifespan
	)
	get_tree().current_scene.add_child(trail)
	trail.global_position = global_position
	_trail = trail


func despawn(hit_pos: Vector3) -> void:
	global_position = hit_pos
	if _trail != null and is_instance_valid(_trail):
		_trail.global_position = hit_pos
	_finish_trail()
	queue_free()


func _finish_trail() -> void:
	if _trail == null or not is_instance_valid(_trail):
		return
	_trail.finish(trail_ttl_after_death)
	_trail = null
