extends Node3D

const WORLD_LEVEL_TERRAIN_PATH := NodePath("WorldLevel/level")
const WORLD_LEVEL_TERRAIN_MESH_PATH := NodePath("WorldLevel/level/StaticBody3D/Cube_001")
const TERRAIN_GRID_CELL_SIZE := 10000.0
const TERRAIN_GRID_CELL_COUNT := 12
const TERRAIN_GRID_INNER_MIN_INDEX := 1
const TERRAIN_GRID_INNER_MAX_INDEX := TERRAIN_GRID_CELL_COUNT - 2
const TERRAIN_ROTATION_QUARTER_COUNT := 4
const TERRAIN_ROTATION_STEP_RAD := PI * 0.5
const RANDOMIZATION_CELL_X_KEY := "cell_x"
const RANDOMIZATION_CELL_Z_KEY := "cell_z"
const RANDOMIZATION_ROTATION_QUARTER_KEY := "rotation_quarter"
const DEBUG_GRID_NODE_NAME := "WorldLevelGridDebug"
const DEBUG_GRID_LINES_NODE_NAME := "GridLines"
const DEBUG_GRID_HEIGHT_OFFSET := 250.0
const DEBUG_GRID_LABEL_PIXEL_SIZE := 0.0008
const DEBUG_GRID_LABEL_FONT_SIZE := 22
const DEBUG_GRID_LINE_COLOR := Color(0.0, 0.85, 1.0, 0.62)
const DEBUG_GRID_SELECTED_COLOR := Color(1.0, 0.82, 0.08, 1.0)
const DEBUG_GRID_LABEL_COLOR := Color(0.72, 0.95, 1.0, 0.7)
const DEBUG_GRID_SELECTED_LABEL_COLOR := Color(1.0, 0.9, 0.25, 1.0)

@export var randomize_world_level_location := true
@export var debug_show_world_level_grid := false

var _net_metrics_enabled := false
var _net_metrics_print_summary := false

var net_metrics_enabled: bool:
	get:
		return _net_metrics_enabled
	set(value):
		_net_metrics_enabled = value
		var spawner := find_child("WorldCharacterSpawner", true, false) as WorldCharacterSpawner
		if spawner != null:
			spawner.net_metrics_enabled = value

var net_metrics_print_summary: bool:
	get:
		return _net_metrics_print_summary
	set(value):
		_net_metrics_print_summary = value
		var spawner := find_child("WorldCharacterSpawner", true, false) as WorldCharacterSpawner
		if spawner != null:
			spawner.net_metrics_print_summary = value

func _ready() -> void:
	var world_level_randomization := _apply_world_level_randomization()
	if debug_show_world_level_grid:
		_build_world_level_debug_grid(world_level_randomization)
	call_deferred("_compose_match_systems")


static func make_random_world_level_randomization() -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return {
		RANDOMIZATION_CELL_X_KEY: rng.randi_range(TERRAIN_GRID_INNER_MIN_INDEX, TERRAIN_GRID_INNER_MAX_INDEX),
		RANDOMIZATION_CELL_Z_KEY: rng.randi_range(TERRAIN_GRID_INNER_MIN_INDEX, TERRAIN_GRID_INNER_MAX_INDEX),
		RANDOMIZATION_ROTATION_QUARTER_KEY: rng.randi_range(0, TERRAIN_ROTATION_QUARTER_COUNT - 1),
	}


static func normalize_world_level_randomization(value: Dictionary) -> Dictionary:
	return {
		RANDOMIZATION_CELL_X_KEY: clampi(
			int(value.get(RANDOMIZATION_CELL_X_KEY, TERRAIN_GRID_INNER_MIN_INDEX)),
			TERRAIN_GRID_INNER_MIN_INDEX,
			TERRAIN_GRID_INNER_MAX_INDEX
		),
		RANDOMIZATION_CELL_Z_KEY: clampi(
			int(value.get(RANDOMIZATION_CELL_Z_KEY, TERRAIN_GRID_INNER_MIN_INDEX)),
			TERRAIN_GRID_INNER_MIN_INDEX,
			TERRAIN_GRID_INNER_MAX_INDEX
		),
		RANDOMIZATION_ROTATION_QUARTER_KEY: posmod(
			int(value.get(RANDOMIZATION_ROTATION_QUARTER_KEY, 0)),
			TERRAIN_ROTATION_QUARTER_COUNT
		),
	}


func _compose_match_systems() -> void:
	if find_child("WorldCharacterSpawner", true, false) != null:
		return
	var lobby := get_node_or_null("/root/Lobby")
	if lobby == null or not lobby.has_method("compose_world_scene"):
		return
	lobby.call("compose_world_scene", self)
	var spawner := find_child("WorldCharacterSpawner", true, false) as WorldCharacterSpawner
	if spawner != null:
		spawner.net_metrics_enabled = _net_metrics_enabled
		spawner.net_metrics_print_summary = _net_metrics_print_summary


func _apply_world_level_randomization() -> Dictionary:
	if not randomize_world_level_location:
		return {}

	var terrain_node := get_node_or_null(WORLD_LEVEL_TERRAIN_PATH) as Node3D
	var mesh_node := get_node_or_null(WORLD_LEVEL_TERRAIN_MESH_PATH) as MeshInstance3D
	if terrain_node == null or mesh_node == null:
		push_warning("World level terrain randomization skipped: terrain nodes were not found.")
		return {}
	if mesh_node.mesh == null:
		push_warning("World level terrain randomization skipped: terrain mesh was not found.")
		return {}

	var randomization := _get_world_level_randomization()
	var terrain_aabb := mesh_node.mesh.get_aabb()
	var cell_x := int(randomization[RANDOMIZATION_CELL_X_KEY])
	var cell_z := int(randomization[RANDOMIZATION_CELL_Z_KEY])
	var rotation_quarter := int(randomization[RANDOMIZATION_ROTATION_QUARTER_KEY])
	var mesh_cell_center := Vector3(
		terrain_aabb.position.x + (float(cell_x) + 0.5) * TERRAIN_GRID_CELL_SIZE,
		0.0,
		terrain_aabb.position.z + (float(cell_z) + 0.5) * TERRAIN_GRID_CELL_SIZE
	)
	var mesh_to_terrain := terrain_node.global_transform.affine_inverse() * mesh_node.global_transform
	var terrain_cell_center := mesh_to_terrain * mesh_cell_center
	var terrain_rotation := Basis(Vector3.UP, float(rotation_quarter) * TERRAIN_ROTATION_STEP_RAD)
	terrain_node.transform = Transform3D(
		terrain_rotation,
		Vector3.ZERO - terrain_rotation * terrain_cell_center
	)
	return randomization


func _get_world_level_randomization() -> Dictionary:
	var lobby := get_node_or_null("/root/Lobby")
	if lobby != null and lobby.has_method("get_world_level_randomization"):
		var value: Variant = lobby.call("get_world_level_randomization")
		if value is Dictionary:
			return normalize_world_level_randomization(value as Dictionary)
	return make_random_world_level_randomization()


func _build_world_level_debug_grid(randomization: Dictionary) -> void:
	var mesh_node := get_node_or_null(WORLD_LEVEL_TERRAIN_MESH_PATH) as MeshInstance3D
	if mesh_node == null or mesh_node.mesh == null:
		push_warning("World level debug grid skipped: terrain mesh was not found.")
		return

	var existing_debug_grid := get_node_or_null(DEBUG_GRID_NODE_NAME)
	if existing_debug_grid != null:
		existing_debug_grid.queue_free()

	var terrain_aabb := mesh_node.mesh.get_aabb()
	var grid_y := terrain_aabb.position.y + terrain_aabb.size.y + DEBUG_GRID_HEIGHT_OFFSET
	var debug_root := Node3D.new()
	debug_root.name = DEBUG_GRID_NODE_NAME
	debug_root.top_level = true
	debug_root.global_transform = Transform3D.IDENTITY
	add_child(debug_root)

	var line_material := StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.vertex_color_use_as_albedo = true
	line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	line_material.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)

	var grid_mesh := ImmediateMesh.new()
	grid_mesh.surface_begin(Mesh.PRIMITIVE_LINES, line_material)
	for grid_index in range(TERRAIN_GRID_CELL_COUNT + 1):
		var local_x := terrain_aabb.position.x + float(grid_index) * TERRAIN_GRID_CELL_SIZE
		var local_z := terrain_aabb.position.z + float(grid_index) * TERRAIN_GRID_CELL_SIZE
		_append_debug_grid_line(
			grid_mesh,
			mesh_node.global_transform * Vector3(local_x, grid_y, terrain_aabb.position.z),
			mesh_node.global_transform * Vector3(local_x, grid_y, terrain_aabb.position.z + terrain_aabb.size.z),
			DEBUG_GRID_LINE_COLOR
		)
		_append_debug_grid_line(
			grid_mesh,
			mesh_node.global_transform * Vector3(terrain_aabb.position.x, grid_y, local_z),
			mesh_node.global_transform * Vector3(terrain_aabb.position.x + terrain_aabb.size.x, grid_y, local_z),
			DEBUG_GRID_LINE_COLOR
		)

	if not randomization.is_empty():
		_append_debug_selected_cell(grid_mesh, mesh_node.global_transform, terrain_aabb, grid_y, randomization)
	grid_mesh.surface_end()

	var grid_lines := MeshInstance3D.new()
	grid_lines.name = DEBUG_GRID_LINES_NODE_NAME
	grid_lines.mesh = grid_mesh
	grid_lines.material_override = line_material
	grid_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	debug_root.add_child(grid_lines)

	_add_debug_grid_labels(debug_root, mesh_node.global_transform, terrain_aabb, grid_y, randomization)


func _append_debug_selected_cell(
	grid_mesh: ImmediateMesh,
	mesh_global_transform: Transform3D,
	terrain_aabb: AABB,
	grid_y: float,
	randomization: Dictionary
) -> void:
	var cell_x := int(randomization[RANDOMIZATION_CELL_X_KEY])
	var cell_z := int(randomization[RANDOMIZATION_CELL_Z_KEY])
	var min_x := terrain_aabb.position.x + float(cell_x) * TERRAIN_GRID_CELL_SIZE
	var max_x := min_x + TERRAIN_GRID_CELL_SIZE
	var min_z := terrain_aabb.position.z + float(cell_z) * TERRAIN_GRID_CELL_SIZE
	var max_z := min_z + TERRAIN_GRID_CELL_SIZE
	var corner_a := mesh_global_transform * Vector3(min_x, grid_y, min_z)
	var corner_b := mesh_global_transform * Vector3(max_x, grid_y, min_z)
	var corner_c := mesh_global_transform * Vector3(max_x, grid_y, max_z)
	var corner_d := mesh_global_transform * Vector3(min_x, grid_y, max_z)
	_append_debug_grid_line(grid_mesh, corner_a, corner_b, DEBUG_GRID_SELECTED_COLOR)
	_append_debug_grid_line(grid_mesh, corner_b, corner_c, DEBUG_GRID_SELECTED_COLOR)
	_append_debug_grid_line(grid_mesh, corner_c, corner_d, DEBUG_GRID_SELECTED_COLOR)
	_append_debug_grid_line(grid_mesh, corner_d, corner_a, DEBUG_GRID_SELECTED_COLOR)


func _append_debug_grid_line(grid_mesh: ImmediateMesh, from_point: Vector3, to_point: Vector3, color: Color) -> void:
	grid_mesh.surface_set_color(color)
	grid_mesh.surface_add_vertex(from_point)
	grid_mesh.surface_set_color(color)
	grid_mesh.surface_add_vertex(to_point)


func _add_debug_grid_labels(
	debug_root: Node3D,
	mesh_global_transform: Transform3D,
	terrain_aabb: AABB,
	grid_y: float,
	randomization: Dictionary
) -> void:
	var selected_x := int(randomization.get(RANDOMIZATION_CELL_X_KEY, -1))
	var selected_z := int(randomization.get(RANDOMIZATION_CELL_Z_KEY, -1))
	var rotation_deg := int(randomization.get(RANDOMIZATION_ROTATION_QUARTER_KEY, 0)) * 90
	for cell_x in range(TERRAIN_GRID_CELL_COUNT):
		for cell_z in range(TERRAIN_GRID_CELL_COUNT):
			var is_selected := cell_x == selected_x and cell_z == selected_z
			var label_position := mesh_global_transform * Vector3(
				terrain_aabb.position.x + (float(cell_x) + 0.5) * TERRAIN_GRID_CELL_SIZE,
				grid_y,
				terrain_aabb.position.z + (float(cell_z) + 0.5) * TERRAIN_GRID_CELL_SIZE
			)
			var label_text := "x:%d y:%d" % [cell_x, cell_z]
			if is_selected:
				label_text += "\nrot:%d" % rotation_deg
			_add_debug_grid_label(debug_root, label_text, label_position, is_selected)


func _add_debug_grid_label(debug_root: Node3D, text: String, label_position: Vector3, is_selected: bool) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = label_position
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.no_depth_test = true
	label.font_size = DEBUG_GRID_LABEL_FONT_SIZE
	label.pixel_size = DEBUG_GRID_LABEL_PIXEL_SIZE
	label.modulate = DEBUG_GRID_SELECTED_LABEL_COLOR if is_selected else DEBUG_GRID_LABEL_COLOR
	label.outline_modulate = Color.BLACK
	label.name = "CellLabel"
	debug_root.add_child(label)
