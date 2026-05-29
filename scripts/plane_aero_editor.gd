extends Control

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const PLANE_CHARACTER_SCENE := preload("res://scenes/plane_character.tscn")
const AERO_TABLES_STORE := preload("res://scripts/plane_aero_tables_store.gd")

@onready var _lift_graph: Node = %LiftGraph
@onready var _drag_graph: Node = %DragGraph
@onready var _status_label: Label = %StatusLabel
@onready var _back_button: Button = %BackButton

var _model_plane: Node3D
var _suspend_graph_updates := false
var _save_queued := false


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_back_button.pressed.connect(_on_back_pressed)
	_lift_graph.points_changed.connect(_on_lift_points_changed)
	_drag_graph.points_changed.connect(_on_drag_points_changed)

	_create_model_plane()
	_apply_saved_tables_to_model()
	_refresh_graphs_from_model()

	_status_label.text = "Saved in user://plane_aero_tables.json"
	_back_button.grab_focus()


func _create_model_plane() -> void:
	_model_plane = PLANE_CHARACTER_SCENE.instantiate() as Node3D


func _apply_saved_tables_to_model() -> void:
	if _model_plane == null:
		return

	var payload: Dictionary = AERO_TABLES_STORE.load_payload()
	if payload.is_empty():
		return

	if _model_plane.has_method("set_lift_table"):
		var lift_points := AERO_TABLES_STORE.decode_points(payload.get("lift_table", []))
		if not lift_points.is_empty():
			_model_plane.call("set_lift_table", lift_points)

	if _model_plane.has_method("set_drag_table"):
		var drag_points := AERO_TABLES_STORE.decode_points(payload.get("drag_table", []))
		if not drag_points.is_empty():
			_model_plane.call("set_drag_table", drag_points)


func _refresh_graphs_from_model() -> void:
	_suspend_graph_updates = true

	if _model_plane == null:
		_lift_graph.set_points([])
		_drag_graph.set_points([])
		_suspend_graph_updates = false
		return

	if _model_plane.has_method("get_lift_table"):
		_lift_graph.set_points(_model_plane.call("get_lift_table"))
	if _model_plane.has_method("get_drag_table"):
		_drag_graph.set_points(_model_plane.call("get_drag_table"))

	_suspend_graph_updates = false


func _on_lift_points_changed(points: Array[Vector2]) -> void:
	if _suspend_graph_updates or _model_plane == null:
		return
	if _model_plane.has_method("set_lift_table"):
		_model_plane.call("set_lift_table", points)
	_queue_save()


func _on_drag_points_changed(points: Array[Vector2]) -> void:
	if _suspend_graph_updates or _model_plane == null:
		return
	if _model_plane.has_method("set_drag_table"):
		_model_plane.call("set_drag_table", points)
	_queue_save()


func _queue_save() -> void:
	if _save_queued:
		return
	_save_queued = true
	call_deferred("_save_tables")


func _save_tables() -> void:
	_save_queued = false
	if _model_plane == null:
		return

	var lift_points: Array[Vector2] = []
	var drag_points: Array[Vector2] = []
	if _model_plane.has_method("get_lift_table"):
		lift_points = _model_plane.call("get_lift_table")
	if _model_plane.has_method("get_drag_table"):
		drag_points = _model_plane.call("get_drag_table")

	var save_error: Error = AERO_TABLES_STORE.save_payload(lift_points, drag_points)
	if save_error == OK:
		_status_label.text = "Saved in user://plane_aero_tables.json"
	else:
		_status_label.text = "Save failed: %s" % error_string(save_error)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func _exit_tree() -> void:
	if _model_plane != null and is_instance_valid(_model_plane):
		_model_plane.free()
		_model_plane = null
