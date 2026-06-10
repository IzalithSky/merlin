extends Node3D

const TRAIL_SCENE := preload("res://scenes/wing_trail.tscn")

@export var trail_ttl_after_death: float = 4.0

var _trail: Node = null


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
		trail.set("lifespan", 2.0)
	get_tree().current_scene.add_child(trail)
	trail.global_position = global_position
	_trail = trail


func _process(_delta: float) -> void:
	if _trail != null and is_instance_valid(_trail):
		_trail.global_position = global_position


func apply_state(t: Transform3D) -> void:
	global_transform = t
	if _trail != null and is_instance_valid(_trail):
		_trail.global_position = t.origin


func die() -> void:
	if _trail != null and is_instance_valid(_trail):
		_trail.set("trail_enabled", false)
		_trail.set("permanent", false)
		_trail.set("node_ttl", trail_ttl_after_death)
		_trail = null
	queue_free()
