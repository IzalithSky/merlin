class_name LockableTarget
extends Node

const TARGET_KIND_NONE := -1
const TARGET_KIND_PLANE := 1

@export var target_kind: int = TARGET_KIND_NONE
@export var target_id: int = -1
@export var team_id: int = 0
@export var aim_offset: Vector3 = Vector3.ZERO


func is_lockable() -> bool:
	return not is_destroyed()


func is_destroyed() -> bool:
	return false


func get_aim_point() -> Vector3:
	var host := get_host_node()
	if host == null:
		return Vector3.ZERO
	return host.global_position + aim_offset


func get_team_id() -> int:
	return team_id


func get_target_id() -> int:
	return target_id


func get_target_kind() -> int:
	return target_kind


func set_target_id(new_target_id: int) -> void:
	target_id = new_target_id


func get_host_node() -> Node3D:
	return get_parent() as Node3D
