class_name GroundLockableTarget
extends LockableTarget

const TARGET_KIND_GROUND := 2


func is_lockable() -> bool:
	var unit := get_parent() as GroundUnit
	return unit != null and is_instance_valid(unit) and not unit.is_shot_down


func is_destroyed() -> bool:
	var unit := get_parent() as GroundUnit
	return unit == null or not is_instance_valid(unit) or unit.is_shot_down


func get_team_id() -> int:
	var unit := get_parent() as GroundUnit
	if unit == null:
		return 0
	return unit.team_id


func get_target_id() -> int:
	var unit := get_parent() as GroundUnit
	if unit == null:
		return -1
	return unit.ground_unit_id


func get_target_kind() -> int:
	return TARGET_KIND_GROUND


func get_host_node() -> Node3D:
	return get_parent() as Node3D
