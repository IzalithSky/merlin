extends Node3D

const TRAIL_SCENE := preload("res://scenes/wing_trail.tscn")

@export var trail_lifespan: float = 0.05
@export var trail_ttl_after_death: float = 0.5

var _velocity: Vector3 = Vector3.ZERO
var _trail: Node = null


func init(pos: Vector3, vel: Vector3) -> void:
	global_position = pos
	_velocity = vel
	if vel.length_squared() > 0.000001:
		look_at(global_position + vel.normalized(), Vector3.UP)
	_spawn_trail()


func _process(delta: float) -> void:
	global_position += _velocity * delta
	if _velocity.length_squared() > 0.000001:
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


func _spawn_trail() -> void:
	var trail := TRAIL_SCENE.instantiate()
	if "permanent" in trail:
		trail.set("permanent", false)
	if "trail_enabled" in trail:
		trail.set("trail_enabled", true)
	if "start_color" in trail:
		trail.set("start_color", Color(1.0, 0.4, 0.7, 0.85))
	if "end_color" in trail:
		trail.set("end_color", Color(1.0, 0.4, 0.7, 0.0))
	if "from_width" in trail:
		trail.set("from_width", 0.12)
	if "to_width" in trail:
		trail.set("to_width", 0.015)
	if "motion_delta" in trail:
		trail.set("motion_delta", 0.25)
	if "lifespan" in trail:
		trail.set("lifespan", trail_lifespan)
	get_tree().current_scene.add_child(trail)
	trail.global_position = global_position
	_trail = trail
