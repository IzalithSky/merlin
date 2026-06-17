class_name PlaneTargetingHud
extends CanvasLayer

@export var foe_color: Color = Color(1.0, 0.25, 0.1)
@export var friend_color: Color = Color(0.2, 0.9, 0.3)
@export var selected_color: Color = Color(1.0, 0.85, 0.0)
@export var locked_color: Color = Color(1.0, 0.45, 0.0)

signal selection_changed(target: Node3D)
signal lock_acquired(target: Node3D)
signal lock_lost()

const MARKER_SIZE := 32.0
const LABEL_WIDTH := 72.0
const LABEL_HEIGHT := 14.0

var _owner_plane = null
var _camera: Camera3D = null
var _selected_target: Node3D = null
var _weapon_lock = null
var _markers: Dictionary = {}

var _tex_foe: Texture2D = null
var _tex_friend: Texture2D = null
var _tex_lock: Texture2D = null

@onready var _overlay: Control = $Overlay


func _ready() -> void:
	_tex_foe = load("res://textures/targeting/marker_a.png")
	_tex_friend = load("res://textures/targeting/marker_v.png")
	_tex_lock = load("res://textures/targeting/lock_sprite.png")


func set_target(owner_plane: Node3D) -> void:
	_owner_plane = owner_plane
	_clear_all_markers()
	_selected_target = null
	_weapon_lock = null
	if owner_plane != null and is_instance_valid(owner_plane):
		_weapon_lock = owner_plane.get_weapon_lock_component()
		if _weapon_lock != null:
			if not _weapon_lock.lock_acquired.is_connected(_on_lock_acquired):
				_weapon_lock.lock_acquired.connect(_on_lock_acquired)
			if not _weapon_lock.lock_lost.is_connected(_on_lock_lost):
				_weapon_lock.lock_lost.connect(_on_lock_lost)


func set_camera(cam: Camera3D) -> void:
	_camera = cam


func get_selected_target() -> Node3D:
	return _selected_target if is_instance_valid(_selected_target) else null


func get_locked_target() -> Node3D:
	if _weapon_lock != null and is_instance_valid(_weapon_lock):
		return _weapon_lock.get_locked_target()
	return null


func get_lock_progress() -> float:
	if _weapon_lock != null and is_instance_valid(_weapon_lock):
		return _weapon_lock.get_lock_progress()
	return 0.0


func is_in_lock_envelope() -> bool:
	if _weapon_lock != null and is_instance_valid(_weapon_lock):
		return _weapon_lock.is_in_envelope()
	return false


func _process(_delta: float) -> void:
	if _owner_plane == null or not is_instance_valid(_owner_plane):
		return
	if _camera == null or not is_instance_valid(_camera):
		return
	if _is_game_menu_open():
		return

	_handle_input()
	_validate_selection()
	_push_selection_to_lock()
	_update_markers()
	_purge_dead_markers()


func _handle_input() -> void:
	if _owner_plane != null and is_instance_valid(_owner_plane) and _owner_plane.is_shot_down:
		_clear_selection()
		return

	if Input.is_action_just_pressed("target_select"):
		_select_nearest_to_center()
	elif Input.is_action_just_pressed("target_deselect"):
		_clear_selection()
	elif Input.is_action_just_pressed("target_cycle_next"):
		_cycle_selection(1)
	elif Input.is_action_just_pressed("target_cycle_prev"):
		_cycle_selection(-1)


func _validate_selection() -> void:
	if _selected_target != null and not is_instance_valid(_selected_target):
		_clear_selection()


func _push_selection_to_lock() -> void:
	if _weapon_lock != null and is_instance_valid(_weapon_lock):
		_weapon_lock.set_desired_target(get_selected_target())


func _select_nearest_to_center() -> void:
	var center := get_viewport().get_visible_rect().size * 0.5
	var best: Node3D = null
	var best_dsq := INF

	for target in _get_candidates():
		if _camera.is_position_behind(target.global_position):
			continue
		var sp := _camera.unproject_position(target.global_position)
		var d := (sp - center).length_squared()
		if d < best_dsq:
			best_dsq = d
			best = target

	_set_selection(best)


func _clear_selection() -> void:
	_set_selection(null)


func _cycle_selection(direction: int) -> void:
	var center := get_viewport().get_visible_rect().size * 0.5
	var on_screen: Array = []

	for target in _get_candidates():
		if _camera.is_position_behind(target.global_position):
			continue
		var sp := _camera.unproject_position(target.global_position)
		on_screen.append({"target": target, "dsq": (sp - center).length_squared()})

	if on_screen.is_empty():
		return

	on_screen.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.dsq < b.dsq)

	var idx := -1
	for i in range(on_screen.size()):
		if on_screen[i].target == _selected_target:
			idx = i
			break

	idx = posmod(idx + direction, on_screen.size())
	_set_selection(on_screen[idx].target as Node3D)


func _set_selection(target: Node3D) -> void:
	if target == _selected_target:
		return
	_selected_target = target
	selection_changed.emit(_selected_target)


func _get_candidates() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for node in get_tree().get_nodes_in_group("player_character"):
		if not is_instance_valid(node):
			continue
		if node == _owner_plane:
			continue
		if bool(node.get("is_shot_down")):
			continue
		result.append(node as Node3D)
	for node in get_tree().get_nodes_in_group("ground_unit"):
		if not is_instance_valid(node):
			continue
		var unit := node as GroundUnit
		if unit != null and unit.is_shot_down:
			continue
		result.append(node as Node3D)
	return result


func _update_markers() -> void:
	var vp_size := get_viewport().get_visible_rect().size
	var live_ids: Array[int] = []

	for target in _get_candidates():
		var id := target.get_instance_id()

		if _camera.is_position_behind(target.global_position):
			_set_marker_visible(id, false)
			continue

		var sp := _camera.unproject_position(target.global_position)
		if sp.x < 0.0 or sp.x > vp_size.x or sp.y < 0.0 or sp.y > vp_size.y:
			_set_marker_visible(id, false)
			continue

		live_ids.append(id)
		var marker := _get_or_create_marker(id)
		_apply_marker(marker, target, sp)

	for id in _markers.keys():
		if id not in live_ids:
			_set_marker_visible(id, false)


func _get_or_create_marker(id: int) -> Control:
	if _markers.has(id):
		return _markers[id]
	var m := _build_marker()
	_overlay.add_child(m)
	_markers[id] = m
	return m


func _build_marker() -> Control:
	var half := MARKER_SIZE * 0.5
	var label_x := -LABEL_WIDTH * 0.5 + half

	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_SCALE
	icon.size = Vector2(MARKER_SIZE, MARKER_SIZE)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(icon)

	var lock_icon := TextureRect.new()
	lock_icon.name = "Lock"
	lock_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	lock_icon.stretch_mode = TextureRect.STRETCH_SCALE
	lock_icon.size = Vector2(MARKER_SIZE, MARKER_SIZE)
	lock_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lock_icon.texture = _tex_lock
	lock_icon.visible = false
	root.add_child(lock_icon)

	var range_lbl := Label.new()
	range_lbl.name = "Range"
	range_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	range_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	range_lbl.add_theme_font_size_override("font_size", 10)
	range_lbl.position = Vector2(label_x, MARKER_SIZE + 2.0)
	range_lbl.size = Vector2(LABEL_WIDTH, LABEL_HEIGHT)
	root.add_child(range_lbl)

	var state_lbl := Label.new()
	state_lbl.name = "State"
	state_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	state_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	state_lbl.add_theme_font_size_override("font_size", 9)
	state_lbl.position = Vector2(label_x, -(LABEL_HEIGHT + 2.0))
	state_lbl.size = Vector2(LABEL_WIDTH, LABEL_HEIGHT)
	state_lbl.visible = false
	root.add_child(state_lbl)

	return root


func _apply_marker(marker: Control, target: Node3D, screen_pos: Vector2) -> void:
	var half := MARKER_SIZE * 0.5
	marker.position = screen_pos - Vector2(half, half)
	marker.visible = true

	var is_sel := target == _selected_target
	var is_foe := true
	if target != null and target.is_in_group("plane_character"):
		is_foe = target.is_hostile_to(_owner_plane)

	var icon := marker.get_node("Icon") as TextureRect
	var lock_icon := marker.get_node("Lock") as TextureRect
	var range_lbl := marker.get_node("Range") as Label
	var state_lbl := marker.get_node("State") as Label

	var lock_progress := get_lock_progress()
	var locked: bool = _weapon_lock != null and is_instance_valid(_weapon_lock) and _weapon_lock.is_locked()

	icon.texture = _tex_foe if is_foe else _tex_friend

	if is_sel and locked:
		icon.modulate = locked_color
	elif is_sel:
		icon.modulate = selected_color
	elif is_foe:
		icon.modulate = foe_color
	else:
		icon.modulate = friend_color

	var show_lock: bool = is_sel and (lock_progress > 0.0 or locked)
	lock_icon.visible = show_lock
	if show_lock:
		lock_icon.modulate = Color(locked_color.r, locked_color.g, locked_color.b,
			1.0 if locked else lock_progress)

	var dist := target.global_position.distance_to(_owner_plane.global_position)
	range_lbl.text = "%.0fm" % dist
	range_lbl.modulate = selected_color if is_sel else (foe_color if is_foe else friend_color)

	if is_sel:
		state_lbl.visible = true
		if locked:
			state_lbl.text = "LOCK"
			state_lbl.modulate = locked_color
		elif lock_progress > 0.0:
			state_lbl.text = "%.0f%%" % (lock_progress * 100.0)
			state_lbl.modulate = selected_color
		else:
			state_lbl.text = "SEL"
			state_lbl.modulate = selected_color
	else:
		state_lbl.visible = false


func _set_marker_visible(id: int, vis: bool) -> void:
	if _markers.has(id):
		var m: Control = _markers[id]
		if is_instance_valid(m):
			m.visible = vis


func _purge_dead_markers() -> void:
	var dead: Array[int] = []
	for id in _markers.keys():
		if instance_from_id(id) == null:
			dead.append(id)
	for id in dead:
		var m: Control = _markers[id]
		if is_instance_valid(m):
			m.queue_free()
		_markers.erase(id)


func _clear_all_markers() -> void:
	for m in _markers.values():
		if is_instance_valid(m):
			m.queue_free()
	_markers.clear()


func _is_game_menu_open() -> bool:
	for menu in get_tree().get_nodes_in_group("game_menu"):
		if menu.has_method("is_open") and bool(menu.call("is_open")):
			return true
	return false


func _on_lock_acquired(target: Node3D) -> void:
	lock_acquired.emit(target)


func _on_lock_lost() -> void:
	lock_lost.emit()
