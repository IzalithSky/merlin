extends Node3D


const VISUAL_TRAIL_SCRIPT := preload("res://scripts/visual_trail_3d.gd")

@export var trails_enabled := true
@export var min_airspeed := 50.0
@export var min_abs_aoa_deg := 4.0
@export var min_pitch_rate_deg_per_second := 12.0

var _plane: RigidBody3D
var _trails: Array[Node] = []
var _last_plane_position := Vector3.ZERO


func _ready() -> void:
	_plane = get_parent() as RigidBody3D
	_last_plane_position = _plane.global_position if _plane != null else global_position
	_collect_trails()


func _physics_process(delta: float) -> void:
	var active := _should_emit_trails(delta)
	for trail in _trails:
		trail.set("trail_enabled", active)


func _collect_trails() -> void:
	_trails.clear()
	for child in get_children():
		if child.get_script() == VISUAL_TRAIL_SCRIPT:
			_trails.append(child)


func _should_emit_trails(delta: float) -> bool:
	if not trails_enabled or _plane == null:
		return false

	var estimated_speed := 0.0
	if delta > 0.0:
		estimated_speed = _plane.global_position.distance_to(_last_plane_position) / delta
	_last_plane_position = _plane.global_position

	var airspeed := maxf(_plane.linear_velocity.length(), estimated_speed)
	if airspeed < min_airspeed:
		return false

	var abs_aoa := _get_abs_aoa_deg()
	var pitch_rate := _get_abs_pitch_rate_deg_per_second()
	return abs_aoa >= min_abs_aoa_deg or pitch_rate >= min_pitch_rate_deg_per_second


func _get_abs_aoa_deg() -> float:
	if _plane.has_method("get_aoa_deg"):
		return absf(float(_plane.call("get_aoa_deg")))
	return 0.0


func _get_abs_pitch_rate_deg_per_second() -> float:
	var local_angular_velocity := _plane.global_transform.basis.orthonormalized().transposed() * _plane.angular_velocity
	return absf(rad_to_deg(local_angular_velocity.x))
