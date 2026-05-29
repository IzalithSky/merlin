extends CanvasLayer

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

@onready var _menu_root: Control = %MenuRoot
@onready var _restart_button: Button = %RestartButton
@onready var _main_menu_button: Button = %MainMenuButton
@onready var _exit_button: Button = %ExitButton

var _is_open := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("game_menu")
	_restart_button.pressed.connect(_on_restart_pressed)
	_main_menu_button.pressed.connect(_on_main_menu_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)
	_set_open(false, false)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_set_open(not _is_open)
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _is_open


func _set_open(value: bool, update_mouse_mode := true) -> void:
	_is_open = value
	_menu_root.visible = value
	_apply_single_player_pause_state(value)

	if not update_mouse_mode:
		return

	if value:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_restart_button.grab_focus()
	else:
		call_deferred("_capture_mouse")


func _capture_mouse() -> void:
	if _is_open or not DisplayServer.window_is_focused():
		return

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _on_restart_pressed() -> void:
	_set_open(false)
	get_tree().reload_current_scene()


func _on_main_menu_pressed() -> void:
	_set_open(false)
	get_node("/root/Lobby").disconnect_session()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func _on_exit_pressed() -> void:
	_set_open(false)
	get_tree().quit()


func _apply_single_player_pause_state(menu_open: bool) -> void:
	if multiplayer.multiplayer_peer != null:
		if get_tree().paused:
			get_tree().paused = false
		return

	get_tree().paused = menu_open
