class_name PlaneWingTrail
extends Node3D


@export var trails_enabled := true
@export var min_airspeed := 50.0
@export var min_abs_aoa_deg := 4.0
@export var min_pitch_rate_deg_per_second := 12.0
@export var disable_abs_aoa_deg := 3.0
@export var disable_pitch_rate_deg_per_second := 9.0

var _plane: PlaneCharacter
var _trails: Array[VisualTrail3D] = []
var _speed_trails: Array[SpeedColorTrail3D] = []
var _active := false


func _ready() -> void:
	_plane = get_parent() as PlaneCharacter
	_collect_trails()


func _physics_process(delta: float) -> void:
	var active := _should_emit_trails(delta)
	for trail in _trails:
		trail.trail_enabled = active

	if _plane != null:
		var forward_speed := _plane.linear_velocity.dot(_plane.get_frame_forward_axis())
		for trail in _speed_trails:
			trail.trail_enabled = true
			trail.set_current_speed(forward_speed)


func _collect_trails() -> void:
	_trails.clear()
	_speed_trails.clear()
	for child in get_children():
		if child is SpeedColorTrail3D:
			_speed_trails.append(child as SpeedColorTrail3D)
		elif child is VisualTrail3D:
			_trails.append(child as VisualTrail3D)


func _should_emit_trails(_delta: float) -> bool:
	if not trails_enabled or _plane == null:
		_active = false
		return false

	var airspeed := _plane.linear_velocity.length()
	if airspeed < min_airspeed:
		_active = false
		return false

	var abs_aoa := absf(_plane.get_aoa_deg())
	var pitch_rate := absf(rad_to_deg(_plane.get_local_pitch_rate()))
	if _active:
		_active = abs_aoa >= disable_abs_aoa_deg or pitch_rate >= disable_pitch_rate_deg_per_second
	else:
		_active = abs_aoa >= min_abs_aoa_deg or pitch_rate >= min_pitch_rate_deg_per_second
	return _active
