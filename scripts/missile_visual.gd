class_name MissileVisual
extends Node3D

const TRAIL_SCENE := preload("res://scenes/wing_trail.tscn")
const MIN_VECTOR_LENGTH_SQUARED := 0.000001

@export var thrust: float = 12_000.0
@export var drag_coeff: float = 0.1
@export var lateral_force: float = 60_000.0
@export var max_ang_vel_deg: float = 200.0
@export var proximity_radius: float = 15.0
@export var proximity_fuse_delay: float = 0.4
@export var target_loss_grace_period: float = 1.5
@export var seeker_cone_half_angle_deg: float = 60.0
@export var trail_lifespan: float = 2.0
@export var trail_ttl_after_death: float = 4.0

var _trail: Node = null
var _velocity := Vector3.ZERO
var _target: Node3D = null
var _time_since_launch: float = 0.0
var _time_since_target_lost: float = 0.0
var _had_target: bool = false
var _previous_deviation: Vector3 = Vector3.ZERO


func init(transform_value: Transform3D, velocity: Vector3, target: Node3D = null) -> void:
	global_transform = transform_value
	_velocity = velocity
	_target = target
	_had_target = _target != null and is_instance_valid(_target)
	if _velocity.length_squared() > MIN_VECTOR_LENGTH_SQUARED:
		look_at(global_position + _velocity.normalized(), Vector3.UP)


func _ready() -> void:
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


func _physics_process(delta: float) -> void:
	_time_since_launch += delta
	_apply_guidance(delta)
	_velocity += (-global_transform.basis.z * thrust) * delta
	_apply_drag(delta)
	global_position += _velocity * delta
	if _velocity.length_squared() > MIN_VECTOR_LENGTH_SQUARED:
		look_at(global_position + _velocity.normalized(), Vector3.UP)
	if _trail != null and is_instance_valid(_trail):
		_trail.global_position = global_position


func despawn(hit_pos: Vector3) -> void:
	global_position = hit_pos
	if _trail != null and is_instance_valid(_trail):
		_trail.global_position = hit_pos
		_trail.set("trail_enabled", false)
		_trail.set("permanent", false)
		_trail.set("node_ttl", trail_ttl_after_death)
		_trail = null
	queue_free()


func die() -> void:
	if _trail != null and is_instance_valid(_trail):
		_trail.set("trail_enabled", false)
		_trail.set("permanent", false)
		_trail.set("node_ttl", trail_ttl_after_death)
		_trail = null
	queue_free()


func _apply_drag(delta: float) -> void:
	var speed := _velocity.length()
	if speed <= 0.0:
		return
	_velocity -= _velocity * drag_coeff * speed * delta


func _apply_guidance(delta: float) -> void:
	if _time_since_launch < proximity_fuse_delay:
		return

	if _target == null or not is_instance_valid(_target):
		if _had_target:
			_time_since_target_lost += delta
			if _time_since_target_lost >= target_loss_grace_period:
				_target = null
		return

	_had_target = true
	_time_since_target_lost = 0.0
	var deviation := _target.global_position - global_position
	var distance_to_target := deviation.length()
	if distance_to_target <= 0.001 or distance_to_target < proximity_radius:
		return

	var forward := -global_transform.basis.z
	if forward.dot(deviation / distance_to_target) < cos(deg_to_rad(seeker_cone_half_angle_deg)):
		_target = null
		return

	var variation := deviation - _previous_deviation
	_previous_deviation = deviation
	var steer_dir := (deviation + variation).normalized()
	if steer_dir.length_squared() <= MIN_VECTOR_LENGTH_SQUARED:
		return

	var velocity_dir := steer_dir if _velocity.length_squared() <= MIN_VECTOR_LENGTH_SQUARED else _velocity.normalized()
	var lateral := steer_dir - velocity_dir * velocity_dir.dot(steer_dir)
	if lateral.length_squared() > MIN_VECTOR_LENGTH_SQUARED:
		_velocity += lateral.normalized() * lateral_force * delta / 1000.0

	var angle := forward.angle_to(steer_dir)
	if angle <= 0.001:
		return
	var axis := forward.cross(steer_dir)
	if axis.length_squared() <= MIN_VECTOR_LENGTH_SQUARED:
		return
	rotate(axis.normalized(), minf(angle, deg_to_rad(max_ang_vel_deg) * delta))
