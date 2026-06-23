extends Node3D


func _ready() -> void:
	await get_tree().create_timer(0.1).timeout

	var plane := $World.get_node_or_null("characters/PlayerCharacter_1") as Node3D
	_assert(plane != null, "missing plane")

	var launcher := plane.get_node_or_null("MissileLauncher") as Node
	_assert(launcher != null, "missing launcher")
	launcher.set("fire_cooldown", 0.0)

	launcher.call("try_fire")
	await get_tree().process_frame
	launcher.call("try_fire")
	await get_tree().process_frame

	var missiles := get_tree().get_nodes_in_group("missile")
	_assert(missiles.size() >= 2, "expected two missiles, got %d" % missiles.size())

	var first := missiles[0] as Node3D
	var second := missiles[1] as Node3D
	var first_local := plane.to_local(first.global_position)
	var second_local := plane.to_local(second.global_position)

	_assert(first_local.x < 0.0, "first missile did not spawn on left side")
	_assert(second_local.x > 0.0, "second missile did not spawn on right side")

	print("missile_hardpoint_smoke_ok first_x=%.2f second_x=%.2f" % [first_local.x, second_local.x])
	_finish(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	_finish(1)


func _finish(exit_code: int) -> void:
	call_deferred("_deferred_finish", exit_code)


func _deferred_finish(exit_code: int) -> void:
	var tree := get_tree()
	await tree.process_frame
	var scene := tree.current_scene
	if scene != null and is_instance_valid(scene):
		scene.free()
	tree.quit(exit_code)
