extends Node3D

const WORLD_SCENE := preload("res://scenes/world_0.tscn")
const MISSION_CONTROLLER_SCRIPT := preload("res://scripts/mission_controller.gd")


func _ready() -> void:
	var lobby := get_node("/root/Lobby")
	lobby.disconnect_session()
	_assert_resolver_defaults()

	var world_root := WORLD_SCENE.instantiate()
	add_child(world_root)

	await _wait_for_world_randomization(lobby)

	_assert(world_root.get_node_or_null("WorldLevelGridDebug") == null, "expected debug grid off by default")
	var randomization: Dictionary = lobby.get_world_level_randomization()
	var terrain_node := world_root.get_node("WorldLevel/level") as Node3D
	var mesh_node := world_root.get_node("WorldLevel/level/StaticBody3D/Cube_001") as MeshInstance3D
	var terrain_aabb := mesh_node.mesh.get_aabb()
	var grid_size := float(randomization["grid_size"])
	var cell_center := Vector3(
		terrain_aabb.position.x + (float(randomization["cell_x"]) + 0.5) * grid_size,
		0.0,
		terrain_aabb.position.z + (float(randomization["cell_z"]) + 0.5) * grid_size
	)
	var global_cell_center := mesh_node.global_transform * cell_center
	_assert(absf(global_cell_center.x) <= 0.01, "expected selected terrain cell center x at world origin")
	_assert(absf(global_cell_center.z) <= 0.01, "expected selected terrain cell center z at world origin")

	var expected_basis := Basis(
		Vector3.UP,
		float(randomization["rotation_quarter"]) * PI * 0.5
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

	await _wait_for_debug_grid(debug_world_root)

	var debug_grid := debug_world_root.get_node_or_null("WorldLevelGridDebug")
	_assert(debug_grid != null, "expected debug grid when flag is enabled")
	_assert(debug_grid.get_node_or_null("GridLines") is MeshInstance3D, "expected debug grid line mesh")
	_assert(debug_grid.get_child_count() > 100, "expected debug grid cell labels")
	var first_label := debug_grid.get_node_or_null("CellLabel") as Label3D
	_assert(first_label != null, "expected debug grid labels")
	_assert(first_label.pixel_size <= 0.001, "expected compact debug grid labels")

	print("world_level_randomizer_smoke_ok randomization=%s" % str(randomization))
	get_tree().quit(0)


func _assert_resolver_defaults() -> void:
	var fixed: Dictionary = MISSION_CONTROLLER_SCRIPT.resolve_world_level_randomization({
		"terrain": {
			"randomize": false,
			"grid_size": 10000,
		}
	})
	_assert(int(fixed["cell_x"]) == 0, "expected fixed terrain x default 0")
	_assert(int(fixed["cell_z"]) == 0, "expected fixed terrain y default 0")
	_assert(int(fixed["rotation_quarter"]) == 0, "expected fixed terrain rotation default 0")

	var configured: Dictionary = MISSION_CONTROLLER_SCRIPT.resolve_world_level_randomization({
		"terrain": {
			"randomize": false,
			"grid_size": 20000,
			"square": [2, 3],
			"rotation": 180,
		}
	})
	_assert(int(configured["cell_x"]) == 2, "expected configured terrain x")
	_assert(int(configured["cell_z"]) == 3, "expected configured terrain y")
	_assert(int(configured["rotation_quarter"]) == 2, "expected configured terrain rotation")
	_assert(is_equal_approx(float(configured["grid_size"]), 20000.0), "expected configured terrain grid size")

	var random: Dictionary = MISSION_CONTROLLER_SCRIPT.resolve_world_level_randomization({
		"terrain": {
			"randomize": true,
			"grid_size": 10000,
		}
	})
	_assert(int(random["cell_x"]) >= 1 and int(random["cell_x"]) <= 10, "expected random terrain x inside edge")
	_assert(int(random["cell_z"]) >= 1 and int(random["cell_z"]) <= 10, "expected random terrain y inside edge")
	_assert(int(random["rotation_quarter"]) >= 0 and int(random["rotation_quarter"]) <= 3, "expected random terrain rotation")


func _wait_for_world_randomization(lobby: Node) -> void:
	for _index in range(10):
		await get_tree().process_frame
		if not (lobby.call("get_world_level_randomization") as Dictionary).is_empty():
			return
	_assert(false, "timed out waiting for world level randomization")


func _wait_for_debug_grid(world_root: Node) -> void:
	for _index in range(10):
		await get_tree().process_frame
		if world_root.get_node_or_null("WorldLevelGridDebug") != null:
			return
	_assert(false, "timed out waiting for debug grid")


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	get_tree().quit(1)
