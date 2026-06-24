extends Window
class_name SurfaceGraph3D

## A popup window that renders a 3D surface F(speed, gamma) built by the flight
## model's sustained-turn surface builders. Speed maps to X, the surface value to
## Y (height), and gamma maps to Z. Left-drag to orbit, mouse wheel to zoom.
##
## The window builds its 3D scene programmatically so it can be instantiated from
## code without a dedicated scene file.

const PLOT_SPAN := 1.0
const HEIGHT_SPAN := 0.7
const ORBIT_SPEED := 0.01
const ZOOM_STEP := 1.12
const MIN_DISTANCE := 0.6
const MAX_DISTANCE := 8.0

const COLOR_BACKGROUND := Color(0.04, 0.06, 0.08, 1.0)
const COLOR_BOX := Color(0.35, 0.46, 0.52, 0.7)
const COLOR_TEXT := Color(0.85, 0.91, 0.96, 1.0)

var _viewport: SubViewport
var _camera: Camera3D
var _pivot: Node3D
var _surface_mesh: MeshInstance3D
var _labels_root: Node3D

var _yaw := 0.7
var _pitch := 0.6
var _distance := 2.6
var _dragging := false


func _init() -> void:
	title = "Surface"
	size = Vector2i(720, 560)
	min_size = Vector2i(360, 280)
	unresizable = false
	close_requested.connect(_on_close_requested)
	_build_scene()


func _build_scene() -> void:
	var background := ColorRect.new()
	background.color = COLOR_BACKGROUND
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var container := SubViewportContainer.new()
	container.stretch = true
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	container.add_child(_viewport)

	_pivot = Node3D.new()
	_pivot.position = Vector3(0.0, HEIGHT_SPAN * 0.5, 0.0)
	_viewport.add_child(_pivot)

	_camera = Camera3D.new()
	_viewport.add_child(_camera)

	var key_light := DirectionalLight3D.new()
	key_light.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(40.0), 0.0)
	key_light.light_energy = 1.1
	_viewport.add_child(key_light)

	var fill_light := DirectionalLight3D.new()
	fill_light.rotation = Vector3(deg_to_rad(-20.0), deg_to_rad(-140.0), 0.0)
	fill_light.light_energy = 0.4
	_viewport.add_child(fill_light)

	_surface_mesh = MeshInstance3D.new()
	_viewport.add_child(_surface_mesh)

	_labels_root = Node3D.new()
	_viewport.add_child(_labels_root)

	# An input overlay sits above the viewport display so we can orbit/zoom.
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(_on_overlay_input)
	add_child(overlay)

	_update_camera()


func show_surface(data: Dictionary, window_title: String) -> void:
	title = window_title
	_build_surface_mesh(data)
	_update_camera()


func _on_close_requested() -> void:
	hide()


func _on_overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_distance = clampf(_distance / ZOOM_STEP, MIN_DISTANCE, MAX_DISTANCE)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_distance = clampf(_distance * ZOOM_STEP, MIN_DISTANCE, MAX_DISTANCE)
			_update_camera()
	elif event is InputEventMouseMotion and _dragging:
		_yaw -= event.relative.x * ORBIT_SPEED
		_pitch = clampf(_pitch + event.relative.y * ORBIT_SPEED, -1.4, 1.4)
		_update_camera()


func _update_camera() -> void:
	if _camera == null:
		return
	var center: Vector3 = _pivot.position
	var offset := Vector3(
		_distance * cos(_pitch) * sin(_yaw),
		_distance * sin(_pitch),
		_distance * cos(_pitch) * cos(_yaw)
	)
	_camera.look_at_from_position(center + offset, center, Vector3.UP)


func _build_surface_mesh(data: Dictionary) -> void:
	_clear_children(_labels_root)
	_surface_mesh.mesh = null

	var points: Array = data.get("points", [])
	var speed_count := int(data.get("speed_count", 0))
	var gamma_count := int(data.get("gamma_count", 0))
	if points.is_empty() or speed_count < 2 or gamma_count < 2:
		return

	var speed_min := INF
	var speed_max := -INF
	var gamma_min := INF
	var gamma_max := -INF
	var value_min := INF
	var value_max := -INF
	for point: Vector3 in points:
		speed_min = minf(speed_min, point.x)
		speed_max = maxf(speed_max, point.x)
		value_min = minf(value_min, point.y)
		value_max = maxf(value_max, point.y)
		gamma_min = minf(gamma_min, point.z)
		gamma_max = maxf(gamma_max, point.z)

	var speed_span := maxf(speed_max - speed_min, 0.0001)
	var gamma_span := maxf(gamma_max - gamma_min, 0.0001)
	var value_span := maxf(value_max - value_min, 0.0001)

	var gradient := _make_gradient()
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	for gamma_index in range(gamma_count - 1):
		for speed_index in range(speed_count - 1):
			var i00 := gamma_index * speed_count + speed_index
			var i10 := gamma_index * speed_count + speed_index + 1
			var i01 := (gamma_index + 1) * speed_count + speed_index
			var i11 := (gamma_index + 1) * speed_count + speed_index + 1
			_add_triangle(surface, gradient, points[i00], points[i10], points[i11],
				speed_min, speed_span, gamma_min, gamma_span, value_min, value_span)
			_add_triangle(surface, gradient, points[i00], points[i11], points[i01],
				speed_min, speed_span, gamma_min, gamma_span, value_min, value_span)

	surface.generate_normals()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 0.85
	surface.set_material(material)
	_surface_mesh.mesh = surface.commit()

	_build_bounding_box()
	_build_axis_labels(
		data.get("x_label", "Speed (m/s)"),
		data.get("y_label", "Value"),
		data.get("z_label", "γ (deg)"),
		speed_min, speed_max, value_min, value_max, gamma_min, gamma_max
	)


func _add_triangle(
	surface: SurfaceTool,
	gradient: Gradient,
	a: Vector3, b: Vector3, c: Vector3,
	speed_min: float, speed_span: float,
	gamma_min: float, gamma_span: float,
	value_min: float, value_span: float
) -> void:
	var triangle: Array[Vector3] = [a, b, c]
	for point in triangle:
		var nx := (point.x - speed_min) / speed_span - 0.5
		var nz := (point.z - gamma_min) / gamma_span - 0.5
		var ny := (point.y - value_min) / value_span
		surface.set_color(gradient.sample(clampf(ny, 0.0, 1.0)))
		surface.add_vertex(Vector3(nx * PLOT_SPAN, ny * HEIGHT_SPAN, nz * PLOT_SPAN))


func _make_gradient() -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.4, 0.7, 1.0])
	gradient.colors = PackedColorArray([
		Color(0.16, 0.32, 0.75),
		Color(0.2, 0.75, 0.55),
		Color(0.9, 0.82, 0.25),
		Color(0.92, 0.32, 0.22),
	])
	return gradient


func _build_bounding_box() -> void:
	var half := PLOT_SPAN * 0.5
	var corners := [
		Vector3(-half, 0.0, -half),
		Vector3(half, 0.0, -half),
		Vector3(half, 0.0, half),
		Vector3(-half, 0.0, half),
		Vector3(-half, HEIGHT_SPAN, -half),
		Vector3(half, HEIGHT_SPAN, -half),
		Vector3(half, HEIGHT_SPAN, half),
		Vector3(-half, HEIGHT_SPAN, half),
	]
	var edges := [
		[0, 1], [1, 2], [2, 3], [3, 0],
		[4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge in edges:
		lines.surface_add_vertex(corners[edge[0]])
		lines.surface_add_vertex(corners[edge[1]])
	lines.surface_end()
	var box := MeshInstance3D.new()
	box.mesh = lines
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = COLOR_BOX
	box.material_override = material
	_labels_root.add_child(box)


func _build_axis_labels(
	x_label: String, y_label: String, z_label: String,
	speed_min: float, speed_max: float,
	value_min: float, value_max: float,
	gamma_min: float, gamma_max: float
) -> void:
	var half := PLOT_SPAN * 0.5
	_add_label(x_label, Vector3(0.0, -0.08, half + 0.12), 0.06)
	_add_label("%.0f" % speed_min, Vector3(-half, -0.06, half + 0.05), 0.045)
	_add_label("%.0f" % speed_max, Vector3(half, -0.06, half + 0.05), 0.045)

	_add_label(z_label, Vector3(-half - 0.18, -0.08, 0.0), 0.06)
	_add_label("%.0f" % gamma_min, Vector3(-half - 0.1, -0.06, -half), 0.045)
	_add_label("%.0f" % gamma_max, Vector3(-half - 0.1, -0.06, half), 0.045)

	_add_label(y_label, Vector3(-half - 0.18, HEIGHT_SPAN + 0.08, -half), 0.06)
	_add_label("%.1f" % value_min, Vector3(-half - 0.1, 0.0, -half), 0.045)
	_add_label("%.1f" % value_max, Vector3(-half - 0.1, HEIGHT_SPAN, -half), 0.045)


func _add_label(text: String, label_position: Vector3, font_size: float) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = label_position
	label.pixel_size = font_size * 0.02
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = COLOR_TEXT
	label.no_depth_test = true
	_labels_root.add_child(label)


func _clear_children(node: Node) -> void:
	for child in node.get_children():
		child.queue_free()
