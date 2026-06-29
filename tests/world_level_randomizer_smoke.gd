extends Node3D

const WORLD_SCENE := preload("res://scenes/world_0.tscn")
const WORLD_SESSION_ROOT_SCRIPT := preload("res://scripts/world_session_root.gd")


func _ready() -> void:
	var lobby := get_node("/root/Lobby")
	lobby.disconnect_session()

	var world_root := WORLD_SCENE.instantiate()
	add_child(world_root)

	await get_tree().process_frame

	_assert(world_root.get_node_or_null("WorldLevelGridDebug") == null, "expected debug grid off by default")
	var randomization: Dictionary = lobby.get_world_level_randomization()
	var terrain_node := world_root.get_node("WorldLevel/level") as Node3D
	var mesh_node := world_root.get_node("WorldLevel/level/StaticBody3D/Cube_001") as MeshInstance3D
	var terrain_aabb := mesh_node.mesh.get_aabb()
	var cell_center := Vector3(
		terrain_aabb.position.x + (float(randomization["cell_x"]) + 0.5) * WORLD_SESSION_ROOT_SCRIPT.TERRAIN_GRID_CELL_SIZE,
		0.0,
		terrain_aabb.position.z + (float(randomization["cell_z"]) + 0.5) * WORLD_SESSION_ROOT_SCRIPT.TERRAIN_GRID_CELL_SIZE
	)
	var global_cell_center := mesh_node.global_transform * cell_center
	_assert(absf(global_cell_center.x) <= 0.01, "expected selected terrain cell center x at world origin")
	_assert(absf(global_cell_center.z) <= 0.01, "expected selected terrain cell center z at world origin")

	var expected_basis := Basis(
		Vector3.UP,
		float(randomization["rotation_quarter"]) * WORLD_SESSION_ROOT_SCRIPT.TERRAIN_ROTATION_STEP_RAD
	)
	_assert(
		terrain_node.global_transform.basis.x.normalized().distance_to(expected_basis.x.normalized()) <= 0.001,
		"expected terrain x basis to match randomized quarter rotation"
	)

	world_root.queue_free()
	await get_tree().process_frame

	var debug_world_root := WORLD_SCENE.instantiate()
	debug_world_root.set("debug_show_world_level_grid", true)
	add_child(debug_world_root)

	await get_tree().process_frame

	var debug_grid := debug_world_root.get_node_or_null("WorldLevelGridDebug")
	_assert(debug_grid != null, "expected debug grid when flag is enabled")
	_assert(debug_grid.get_node_or_null("GridLines") is MeshInstance3D, "expected debug grid line mesh")
	_assert(debug_grid.get_child_count() > 100, "expected debug grid cell labels")
	var first_label := debug_grid.get_node_or_null("CellLabel") as Label3D
	_assert(first_label != null, "expected debug grid labels")
	_assert(first_label.pixel_size <= 0.001, "expected compact debug grid labels")

	print("world_level_randomizer_smoke_ok randomization=%s" % str(randomization))
	get_tree().quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	get_tree().quit(1)
