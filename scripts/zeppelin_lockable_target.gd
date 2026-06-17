class_name ZeppelinLockableTarget
extends LockableTarget

const TARGET_KIND_ZEPPELIN := 3


func is_lockable() -> bool:
	var zep := get_parent()
	return zep != null and is_instance_valid(zep) and not bool(zep.get("is_shot_down"))


func is_destroyed() -> bool:
	var zep := get_parent()
	return zep == null or not is_instance_valid(zep) or bool(zep.get("is_shot_down"))


func get_team_id() -> int:
	var zep := get_parent()
	return int(zep.get("team_id")) if zep != null else 0


func get_target_id() -> int:
	var zep := get_parent()
	return int(zep.get("zeppelin_id")) if zep != null else -1


func get_target_kind() -> int:
	return TARGET_KIND_ZEPPELIN


func get_host_node() -> Node3D:
	return get_parent() as Node3D
