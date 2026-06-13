class_name PlaneLockableTarget
extends "res://scripts/lockable_target.gd"


func is_lockable() -> bool:
	var plane := _get_plane()
	return plane != null and is_instance_valid(plane) and not plane.is_shot_down


func is_destroyed() -> bool:
	var plane := _get_plane()
	return plane == null or not is_instance_valid(plane) or plane.is_shot_down


func get_team_id() -> int:
	var plane := _get_plane()
	if plane == null:
		return 0
	return plane.team_id


func get_target_id() -> int:
	var plane := _get_plane()
	if plane == null:
		return -1
	return plane.peer_id


func get_target_kind() -> int:
	return TARGET_KIND_PLANE


func get_host_node() -> Node3D:
	return _get_plane()


func _get_plane() -> PlaneCharacter:
	return get_parent() as PlaneCharacter
