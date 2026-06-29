class_name MissileLockableTarget
extends LockableTarget

const TARGET_KIND_MISSILE := 4


func is_lockable() -> bool:
	var missile := get_parent()
	return missile != null and is_instance_valid(missile)


func is_destroyed() -> bool:
	var missile := get_parent()
	return missile == null or not is_instance_valid(missile)


func get_target_id() -> int:
	var missile := get_parent() as Missile
	if missile == null:
		return -1
	return missile.missile_target_id


func get_target_kind() -> int:
	return TARGET_KIND_MISSILE


func get_host_node() -> Node3D:
	return get_parent() as Node3D
