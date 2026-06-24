extends Control

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const PLANE_CHARACTER_SCENE := preload("res://scenes/plane_character.tscn")
const AERO_TABLES_STORE := preload("res://scripts/plane_aero_tables_store.gd")
const TURN_PERFORMANCE_GRAPH_SCRIPT := preload("res://scripts/turn_performance_graph.gd")
const SURFACE_GRAPH_3D_SCRIPT := preload("res://scripts/surface_graph_3d.gd")

@onready var _lift_graph: Node = %LiftGraph
@onready var _drag_graph: Node = %DragGraph
@onready var _control_authority_graph: Node = %ControlAuthorityGraph
@onready var _thrust_graph: Node = %ThrustGraph
@onready var _em_rate_graph: Control = %EMRateGraph
@onready var _em_radius_graph: Control = %EMRadiusGraph
@onready var _em_summary_label: Label = %EMSummaryLabel
@onready var _em_legend_rate: RichTextLabel = %EMLegendRate
@onready var _em_legend_radius: RichTextLabel = %EMLegendRadius
@onready var _em_gamma_spin: SpinBox = %GammaSpin
@onready var _aoa_surface_button: Button = %AoaSurfaceButton
@onready var _rate_surface_button: Button = %RateSurfaceButton
@onready var _status_label: Label = %StatusLabel
@onready var _back_button: Button = %BackButton
@onready var _params_grid: GridContainer = %ParamsGrid
@onready var _preset_option: OptionButton = %PresetOption
@onready var _overwrite_button: Button = %OverwriteButton
@onready var _save_as_button: Button = %SaveAsButton
@onready var _delete_button: Button = %DeleteButton

var _model_plane: Node3D
var _suspend_graph_updates := false
var _suspend_param_updates := false
var _save_queued := false
var _dirty := false
var _navigating := false
var _em_gamma_deg := 0.0
var _param_spins: Dictionary = {}
var _current_preset: Dictionary = {
	"source": AERO_TABLES_STORE.SOURCE_BUILTIN,
	"id": AERO_TABLES_STORE.DEFAULT_PRESET_ID,
	"name": "default",
}
var _save_as_dialog: ConfirmationDialog
var _save_as_edit: LineEdit
var _aoa_surface_window: Window
var _rate_surface_window: Window


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_back_button.pressed.connect(_on_back_pressed)
	_lift_graph.points_changed.connect(_on_lift_points_changed)
	_drag_graph.points_changed.connect(_on_drag_points_changed)
	_control_authority_graph.points_changed.connect(_on_control_authority_points_changed)
	_thrust_graph.points_changed.connect(_on_thrust_points_changed)
	_preset_option.item_selected.connect(_on_preset_selected)
	_overwrite_button.pressed.connect(_on_overwrite_pressed)
	_save_as_button.pressed.connect(_on_save_as_pressed)
	_delete_button.pressed.connect(_on_delete_pressed)
	_em_gamma_spin.value_changed.connect(_on_em_gamma_changed)
	_aoa_surface_button.pressed.connect(_on_aoa_surface_pressed)
	_rate_surface_button.pressed.connect(_on_rate_surface_pressed)
	_build_save_as_dialog()

	_create_model_plane()
	var active: Dictionary = AERO_TABLES_STORE.load_payload()
	_current_preset = {
		"source": String(active.get("source", AERO_TABLES_STORE.SOURCE_BUILTIN)),
		"id": String(active.get("id", AERO_TABLES_STORE.DEFAULT_PRESET_ID)),
		"name": String(active.get("name", "default")),
	}
	_dirty = bool(active.get("dirty", false))
	if _model_plane.has_method("apply_aero_tables_payload"):
		_model_plane.call("apply_aero_tables_payload", active)
	_refresh_graphs_from_model()
	_build_param_fields()
	_configure_em_legends()
	_refresh_em_diagrams()

	_populate_preset_dropdown()
	_update_preset_buttons()
	_update_status()
	_back_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_on_back_pressed()


func _create_model_plane() -> void:
	_model_plane = PLANE_CHARACTER_SCENE.instantiate() as Node3D


func _load_payload_into_model(payload: Dictionary) -> void:
	if _model_plane != null and _model_plane.has_method("apply_aero_tables_payload"):
		_model_plane.call("apply_aero_tables_payload", payload)
		_refresh_graphs_from_model()
		_refresh_param_fields()
		_refresh_em_diagrams()


func _build_param_fields() -> void:
	for spec: Dictionary in AERO_TABLES_STORE.PARAM_SPECS:
		var key: String = spec["key"]

		var label := Label.new()
		label.text = spec["label"]
		label.custom_minimum_size = Vector2(150, 0)
		label.size_flags_vertical = Control.SIZE_SHRINK_CENTER

		var spin := SpinBox.new()
		spin.min_value = spec["min"]
		spin.max_value = spec["max"]
		spin.step = spec["step"]
		spin.allow_greater = true
		spin.custom_minimum_size = Vector2(108, 0)
		if _model_plane != null:
			spin.value = _model_plane.get(key)
		spin.value_changed.connect(_on_param_changed.bind(key))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(label)
		row.add_child(spin)
		_params_grid.add_child(row)
		_param_spins[key] = spin


func _refresh_param_fields() -> void:
	if _model_plane == null:
		return
	_suspend_param_updates = true
	for key: String in _param_spins:
		_param_spins[key].value = _model_plane.get(key)
	_suspend_param_updates = false


func _on_param_changed(value: float, key: String) -> void:
	if _suspend_param_updates or _model_plane == null:
		return
	_model_plane.set(key, value)
	_refresh_em_diagrams()
	_mark_dirty()


# Flight-path angle is an EM analysis input only (climb/dive turns); it is not a
# saved plane parameter, so it just re-runs the diagram without marking dirty.
func _on_em_gamma_changed(value: float) -> void:
	_em_gamma_deg = value
	_refresh_em_diagrams()


func _on_aoa_surface_pressed() -> void:
	if _model_plane == null or not _model_plane.has_method("build_sustained_turn_aoa_surface"):
		return
	var data: Dictionary = _model_plane.call("build_sustained_turn_aoa_surface", -45.0, 45.0, 61, 0.0, 200.0)
	if data.is_empty():
		return
	data["x_label"] = "Speed (m/s)"
	data["y_label"] = "AoA (deg)"
	data["z_label"] = "γ (deg)"
	_aoa_surface_window = _show_surface_window(
		_aoa_surface_window, data, "Sustained-turn AoA — F(speed, γ)"
	)


func _on_rate_surface_pressed() -> void:
	if _model_plane == null or not _model_plane.has_method("build_sustained_turn_rate_surface"):
		return
	var data: Dictionary = _model_plane.call("build_sustained_turn_rate_surface", -45.0, 45.0, 61, 0.0, 200.0)
	if data.is_empty():
		return
	data["x_label"] = "Speed (m/s)"
	data["y_label"] = "Turn rate (deg/s)"
	data["z_label"] = "γ (deg)"
	_rate_surface_window = _show_surface_window(
		_rate_surface_window, data, "Sustained turn rate — F(speed, γ)"
	)


func _show_surface_window(window: Window, data: Dictionary, window_title: String) -> Window:
	if window == null or not is_instance_valid(window):
		window = SURFACE_GRAPH_3D_SCRIPT.new()
		add_child(window)
	window.call("show_surface", data, window_title)
	window.popup_centered()
	return window


func _refresh_graphs_from_model() -> void:
	_suspend_graph_updates = true

	if _model_plane == null:
		_lift_graph.set_points([])
		_drag_graph.set_points([])
		_control_authority_graph.set_points([])
		_thrust_graph.set_points([])
		_suspend_graph_updates = false
		return

	if _model_plane.has_method("get_lift_table"):
		_lift_graph.set_points(_model_plane.call("get_lift_table"))
	if _model_plane.has_method("get_drag_table"):
		_drag_graph.set_points(_model_plane.call("get_drag_table"))
	if _model_plane.has_method("get_control_authority_table"):
		_control_authority_graph.set_points(_model_plane.call("get_control_authority_table"))
	if _model_plane.has_method("get_thrust_table"):
		_thrust_graph.set_points(_model_plane.call("get_thrust_table"))

	_suspend_graph_updates = false


func _on_lift_points_changed(points: Array[Vector2]) -> void:
	if _suspend_graph_updates or _model_plane == null:
		return
	if _model_plane.has_method("set_lift_table"):
		_model_plane.call("set_lift_table", points)
	_refresh_em_diagrams()
	_mark_dirty()


func _on_drag_points_changed(points: Array[Vector2]) -> void:
	if _suspend_graph_updates or _model_plane == null:
		return
	if _model_plane.has_method("set_drag_table"):
		_model_plane.call("set_drag_table", points)
	_refresh_em_diagrams()
	_mark_dirty()


func _on_control_authority_points_changed(points: Array[Vector2]) -> void:
	if _suspend_graph_updates or _model_plane == null:
		return
	if _model_plane.has_method("set_control_authority_table"):
		_model_plane.call("set_control_authority_table", points)
	_refresh_em_diagrams()
	_mark_dirty()


func _on_thrust_points_changed(points: Array[Vector2]) -> void:
	if _suspend_graph_updates or _model_plane == null:
		return
	if _model_plane.has_method("set_thrust_table"):
		_model_plane.call("set_thrust_table", points)
	_refresh_em_diagrams()
	_mark_dirty()


func _refresh_em_diagrams() -> void:
	if _model_plane == null or not _model_plane.has_method("get_turn_performance"):
		_em_rate_graph.call("set_series", [])
		_em_radius_graph.call("set_series", [])
		_em_summary_label.text = ""
		return
	var performance: Variant = _model_plane.call("get_turn_performance", _em_gamma_deg)
	if not (performance is Dictionary):
		_em_rate_graph.call("set_series", [])
		_em_radius_graph.call("set_series", [])
		_em_summary_label.text = "No valid turn-performance solution."
		return
	var performance_dict: Dictionary = performance
	if performance_dict.is_empty():
		_em_rate_graph.call("set_series", [])
		_em_radius_graph.call("set_series", [])
		_em_summary_label.text = "No valid turn-performance solution at γ = %.0f°." % _em_gamma_deg
		return

	var rate_series: Array[Dictionary] = [
		{
			"points": performance_dict.get("instantaneous_rate_curve", []),
			"marker": Vector2(
				float(performance_dict.get("max_instantaneous_rate_speed", 0.0)),
				float(performance_dict.get("max_instantaneous_rate_deg_s", 0.0))
			),
		},
		{
			"points": performance_dict.get("sustained_rate_curve", []),
			"marker": Vector2(
				float(performance_dict.get("max_sustained_rate_speed", 0.0)),
				float(performance_dict.get("max_sustained_rate_deg_s", 0.0))
			),
		},
	]
	var radius_series: Array[Dictionary] = [
		{
			"points": performance_dict.get("instantaneous_radius_curve", []),
			"marker": Vector2(
				float(performance_dict.get("min_instantaneous_radius_speed", 0.0)),
				float(performance_dict.get("min_instantaneous_radius_m", 0.0))
			),
		},
		{
			"points": performance_dict.get("sustained_radius_curve", []),
			"marker": Vector2(
				float(performance_dict.get("min_sustained_radius_speed", 0.0)),
				float(performance_dict.get("min_sustained_radius_m", 0.0))
			),
		},
	]
	_em_rate_graph.call("set_series", rate_series)
	_em_radius_graph.call("set_series", radius_series)
	_em_summary_label.text = (
		"EM @ γ=%.0f°: corner %.0f m/s · inst %.1f °/s @ %.0f m/s · sus %.1f °/s @ %.0f m/s · inst R %.0f m @ %.0f m/s · sus R %.0f m @ %.0f m/s"
		% [
			_em_gamma_deg,
			float(performance_dict.get("corner_speed", 0.0)),
			float(performance_dict.get("max_instantaneous_rate_deg_s", 0.0)),
			float(performance_dict.get("max_instantaneous_rate_speed", 0.0)),
			float(performance_dict.get("max_sustained_rate_deg_s", 0.0)),
			float(performance_dict.get("max_sustained_rate_speed", 0.0)),
			float(performance_dict.get("min_instantaneous_radius_m", 0.0)),
			float(performance_dict.get("min_instantaneous_radius_speed", 0.0)),
			float(performance_dict.get("min_sustained_radius_m", 0.0)),
			float(performance_dict.get("min_sustained_radius_speed", 0.0)),
		]
	)


func _configure_em_legends() -> void:
	_em_legend_rate.bbcode_enabled = true
	_em_legend_radius.bbcode_enabled = true
	var inst_color := TURN_PERFORMANCE_GRAPH_SCRIPT.get_series_a_color().to_html()
	var sus_color := TURN_PERFORMANCE_GRAPH_SCRIPT.get_series_b_color().to_html()
	var marker_color := TURN_PERFORMANCE_GRAPH_SCRIPT.get_marker_color().to_html()
	_em_legend_rate.text = (
		"[color=#%s]*[/color] instantaneous  [color=#%s]*[/color] sustained  [color=#%s]*[/color] optimum"
		% [inst_color, sus_color, marker_color]
	)
	_em_legend_radius.text = (
		"[color=#%s]*[/color] instantaneous  [color=#%s]*[/color] sustained  [color=#%s]*[/color] minima"
		% [inst_color, sus_color, marker_color]
	)


func _queue_save() -> void:
	if _save_queued:
		return
	_save_queued = true
	call_deferred("_save_tables")


func _save_tables() -> void:
	_save_queued = false
	if _model_plane == null or not _model_plane.has_method("get_aero_tables_payload"):
		return

	var payload: Dictionary = _model_plane.call("get_aero_tables_payload")
	payload["name"] = _current_preset["name"]
	payload["source"] = _current_preset["source"]
	payload["id"] = _current_preset["id"]
	payload["dirty"] = _dirty

	var save_error: Error = AERO_TABLES_STORE.save_payload(payload)
	if save_error == OK:
		_update_status()
	else:
		_set_status("Save failed: %s" % error_string(save_error))


func _model_payload() -> Dictionary:
	if _model_plane == null or not _model_plane.has_method("get_aero_tables_payload"):
		return {}
	return _model_plane.call("get_aero_tables_payload")


func _mark_dirty() -> void:
	if not _dirty:
		_dirty = true
		if _current_preset.get("source", "") == AERO_TABLES_STORE.SOURCE_BUILTIN:
			# Built-ins are immutable; the first edit detaches to an unsaved copy.
			_current_preset = {"source": "", "id": "", "name": "Custom"}
			_populate_preset_dropdown()
			_update_preset_buttons()
		_update_status()
	_queue_save()


func _build_save_as_dialog() -> void:
	_save_as_dialog = ConfirmationDialog.new()
	_save_as_dialog.title = "Save Preset As"
	_save_as_dialog.ok_button_text = "Save"

	var vbox := VBoxContainer.new()
	var label := Label.new()
	label.text = "Preset name:"
	_save_as_edit = LineEdit.new()
	_save_as_edit.custom_minimum_size = Vector2(300, 0)
	vbox.add_child(label)
	vbox.add_child(_save_as_edit)
	_save_as_dialog.add_child(vbox)

	add_child(_save_as_dialog)
	_save_as_dialog.register_text_enter(_save_as_edit)
	_save_as_dialog.confirmed.connect(_on_save_as_confirmed)


func _populate_preset_dropdown() -> void:
	_preset_option.clear()
	var is_custom: bool = String(_current_preset.get("source", "")) == ""
	var select_index := 0
	var next_index := 0

	if is_custom:
		var custom_entry := {"source": "", "id": "", "name": String(_current_preset.get("name", "Custom"))}
		_preset_option.add_item("%s  (unsaved)" % custom_entry["name"])
		_preset_option.set_item_metadata(0, custom_entry)
		next_index = 1

	for entry: Dictionary in AERO_TABLES_STORE.list_presets():
		var label: String = entry["name"]
		if entry["source"] == AERO_TABLES_STORE.SOURCE_BUILTIN:
			label += "  (built-in)"
		_preset_option.add_item(label)
		_preset_option.set_item_metadata(next_index, entry)
		if not is_custom and entry["source"] == _current_preset["source"] and entry["id"] == _current_preset["id"]:
			select_index = next_index
		next_index += 1

	if _preset_option.item_count > 0:
		_preset_option.select(select_index)


func _selected_entry() -> Dictionary:
	var index := _preset_option.selected
	if index < 0:
		return {}
	var meta: Variant = _preset_option.get_item_metadata(index)
	return meta if meta is Dictionary else {}


func _update_preset_buttons() -> void:
	var entry := _selected_entry()
	var source := String(entry.get("source", ""))
	var is_user := source == AERO_TABLES_STORE.SOURCE_USER
	_overwrite_button.disabled = entry.is_empty()
	_delete_button.disabled = not is_user
	if is_user:
		_overwrite_button.tooltip_text = "Overwrite this user preset with the current values."
	else:
		_overwrite_button.tooltip_text = "Read-only/unsaved — this saves a new user preset."


func _on_preset_selected(_index: int) -> void:
	var entry := _selected_entry()
	if entry.is_empty() or String(entry.get("source", "")) == "":
		_update_preset_buttons()
		return
	var payload: Dictionary = AERO_TABLES_STORE.load_preset(entry["source"], entry["id"])
	if payload.is_empty():
		_set_status("Load failed: %s" % entry["id"])
		_update_preset_buttons()
		return
	_current_preset = {
		"source": entry["source"],
		"id": entry["id"],
		"name": String(payload.get("name", entry["name"])),
	}
	_dirty = false
	_load_payload_into_model(payload)
	_queue_save()
	_populate_preset_dropdown()
	_update_preset_buttons()
	_set_status("Loaded preset: %s" % _current_preset["name"])


func _on_overwrite_pressed() -> void:
	var entry := _selected_entry()
	if entry.is_empty():
		return
	if entry["source"] != AERO_TABLES_STORE.SOURCE_USER:
		# Built-in or unsaved custom: can't overwrite — prompt to save a user copy.
		_open_save_as_dialog(String(_current_preset.get("name", "")))
		return
	var result: Dictionary = AERO_TABLES_STORE.save_user_preset(entry["name"], _model_payload())
	if result.is_empty():
		_set_status("Overwrite failed")
		return
	_current_preset = result
	_dirty = false
	_queue_save()
	_populate_preset_dropdown()
	_update_preset_buttons()
	_set_status("Overwrote preset: %s" % result["name"])


func _on_save_as_pressed() -> void:
	_open_save_as_dialog(String(_current_preset.get("name", "")))


func _open_save_as_dialog(suggested_name: String) -> void:
	_save_as_edit.text = suggested_name
	_save_as_dialog.popup_centered()
	_save_as_edit.grab_focus()
	_save_as_edit.select_all()


func _on_save_as_confirmed() -> void:
	var display_name := _save_as_edit.text.strip_edges()
	if display_name.is_empty():
		_set_status("Preset name required")
		return
	var result: Dictionary = AERO_TABLES_STORE.save_user_preset(display_name, _model_payload())
	if result.is_empty():
		_set_status("Save failed")
		return
	_current_preset = result
	_dirty = false
	_queue_save()
	_populate_preset_dropdown()
	_update_preset_buttons()
	_set_status("Saved preset: %s" % result["name"])


func _on_delete_pressed() -> void:
	var entry := _selected_entry()
	if entry.is_empty() or entry["source"] != AERO_TABLES_STORE.SOURCE_USER:
		return
	var delete_error: Error = AERO_TABLES_STORE.delete_user_preset(entry["id"])
	if delete_error != OK:
		_set_status("Delete failed: %s" % error_string(delete_error))
		return
	if _current_preset["source"] == entry["source"] and _current_preset["id"] == entry["id"]:
		# Keep the current values, but they no longer belong to a saved preset.
		_current_preset = {"source": "", "id": "", "name": "Custom"}
		_dirty = true
		_queue_save()
	_populate_preset_dropdown()
	_update_preset_buttons()
	_set_status("Deleted preset: %s" % entry["name"])


func _update_status() -> void:
	var source := String(_current_preset.get("source", ""))
	var label := String(_current_preset.get("name", "Custom"))
	if source == "":
		_set_status("Editing: %s (unsaved) — autosaved to user://plane_aero_tables.json" % label)
		return
	var source_label := "built-in" if source == AERO_TABLES_STORE.SOURCE_BUILTIN else "user"
	var modified := " · modified" if _dirty else ""
	_set_status("Editing: %s (%s%s) — autosaved to user://plane_aero_tables.json" % [label, source_label, modified])


func _set_status(text: String) -> void:
	_status_label.text = text


func _on_back_pressed() -> void:
	# Defer to a frame boundary: tearing the scene down synchronously from
	# within input propagation (the ESC path) can freeze the GUI, e.g. while a
	# graph pan/drag grab is active. Guard against re-entrant navigation.
	if _navigating:
		return
	_navigating = true
	get_tree().change_scene_to_file.call_deferred(MAIN_MENU_SCENE)


func _exit_tree() -> void:
	if _model_plane != null and is_instance_valid(_model_plane):
		_model_plane.free()
		_model_plane = null
