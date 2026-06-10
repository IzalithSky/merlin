extends Node

@export var lock_cone_half_angle_deg: float = 15.0
@export var lock_max_range: float = 4000.0
@export var lock_time_sec: float = 1.5

signal lock_acquired(target: Node3D)
signal lock_lost()

var _desired_target: Node3D = null
var _lock_progress: float = 0.0
var _locked: bool = false


func set_desired_target(t: Node3D) -> void:
	if t == _desired_target:
		return
	if _locked:
		_locked = false
		lock_lost.emit()
	_lock_progress = 0.0
	_desired_target = t


func get_locked_target() -> Node3D:
	if _locked and _desired_target != null and is_instance_valid(_desired_target):
		return _desired_target
	return null


func get_lock_progress() -> float:
	return _lock_progress


func is_locked() -> bool:
	return _locked


func is_in_envelope() -> bool:
	return _check_lock_envelope(_desired_target)


func _physics_process(delta: float) -> void:
	_update_lock(delta)


func _update_lock(delta: float) -> void:
	if _desired_target != null and not is_instance_valid(_desired_target):
		_desired_target = null

	if _desired_target == null:
		if _locked:
			_locked = false
			_lock_progress = 0.0
			lock_lost.emit()
		else:
			_lock_progress = 0.0
		return

	if not _is_lockable(_desired_target):
		if _locked:
			_locked = false
			lock_lost.emit()
		_lock_progress = 0.0
		return

	if _check_lock_envelope(_desired_target):
		_lock_progress = minf(_lock_progress + delta / maxf(lock_time_sec, 0.01), 1.0)
		if not _locked and _lock_progress >= 1.0:
			_locked = true
			lock_acquired.emit(_desired_target)
	else:
		if _locked:
			_locked = false
			lock_lost.emit()
		_lock_progress = 0.0


func _check_lock_envelope(target: Node3D) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var owner_plane := get_parent() as Node3D
	if owner_plane == null:
		return false
	var to_target := target.global_position - owner_plane.global_position
	var dist := to_target.length()
	if dist < 0.001 or dist > lock_max_range:
		return false
	var fwd := -owner_plane.global_transform.basis.z
	var angle := acos(clampf(fwd.dot(to_target / dist), -1.0, 1.0))
	return angle <= deg_to_rad(lock_cone_half_angle_deg)


func _is_lockable(target: Node3D) -> bool:
	return is_instance_valid(target)
