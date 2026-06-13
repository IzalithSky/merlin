class_name PlaneWeaponLock
extends Node

@export var lock_cone_half_angle_deg: float = 15.0
@export var lock_max_range: float = 4000.0
@export var lock_time_sec: float = 0.5

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


func get_locked_target_component():
	var target := get_locked_target()
	if target == null:
		return null
	return _get_lockable_target(target)


func get_desired_target() -> Node3D:
	if _desired_target != null and is_instance_valid(_desired_target):
		return _desired_target
	return null


func get_lock_progress() -> float:
	return _lock_progress


func is_locked() -> bool:
	return _locked


func is_in_envelope() -> bool:
	return _check_lock_envelope(_desired_target)


func is_target_in_envelope(target: Node3D) -> bool:
	return _check_lock_envelope(target)


func is_target_lockable(target: Node3D) -> bool:
	return _get_lockable_target(target) != null and _is_lockable(target)


func _physics_process(delta: float) -> void:
	_update_lock(delta)


func _update_lock(delta: float) -> void:
	var owner_plane := _get_owner_plane()
	if owner_plane != null and owner_plane.is_shot_down:
		_desired_target = null
		if _locked:
			_locked = false
			lock_lost.emit()
		_lock_progress = 0.0
		return

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
	var lockable_target = _get_lockable_target(target)
	if lockable_target == null:
		return false
	var owner_plane := _get_owner_plane()
	if owner_plane == null or owner_plane.is_shot_down:
		return false
	var to_target: Vector3 = lockable_target.get_aim_point() - owner_plane.global_position
	var dist: float = to_target.length()
	if dist < 0.001 or dist > lock_max_range:
		return false
	var fwd := -owner_plane.global_transform.basis.z
	var angle := acos(clampf(fwd.dot(to_target / dist), -1.0, 1.0))
	return angle <= deg_to_rad(lock_cone_half_angle_deg)


func _is_lockable(target: Node3D) -> bool:
	var lockable_target = _get_lockable_target(target)
	if lockable_target == null:
		return false
	return lockable_target.is_lockable()


func _get_lockable_target(target: Node3D):
	if target == null or not is_instance_valid(target):
		return null
	return target.get_node_or_null("LockableTarget")


func _get_owner_plane() -> PlaneCharacter:
	return get_parent() as PlaneCharacter
