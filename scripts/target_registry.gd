class_name TargetRegistry
extends Node

var _targets: Dictionary = {}


func register_target(target) -> void:
	if target == null or not is_instance_valid(target):
		return

	var resolved_target_kind: int = target.get_target_kind()
	var resolved_target_id: int = target.get_target_id()
	if resolved_target_kind < 0 or resolved_target_id < 0:
		return

	_targets[_make_key(resolved_target_kind, resolved_target_id)] = target


func unregister_target(target) -> void:
	if target == null:
		return

	var resolved_target_kind: int = target.get_target_kind()
	var resolved_target_id: int = target.get_target_id()
	if resolved_target_kind < 0 or resolved_target_id < 0:
		return

	_targets.erase(_make_key(resolved_target_kind, resolved_target_id))


func resolve_target(target_kind: int, target_id: int):
	if target_kind < 0 or target_id < 0:
		return null

	var key := _make_key(target_kind, target_id)
	var target = _targets.get(key)
	if target == null:
		return null
	if not is_instance_valid(target):
		_targets.erase(key)
		return null
	return target


func resolve_target_host(target_kind: int, target_id: int) -> Node3D:
	var target = resolve_target(target_kind, target_id)
	if target == null:
		return null
	return target.get_host_node()


func _make_key(target_kind: int, target_id: int) -> String:
	return "%d:%d" % [target_kind, target_id]
