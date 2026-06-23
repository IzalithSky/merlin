extends CanvasLayer

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

@onready var _menu_root: Control = %MenuRoot
@onready var _menu_panel: Control = $MenuRoot/CenterContainer/Panel
@onready var _options_panel: Control = %OptionsPanel
@onready var _keybindings_panel: Control = %KeybindingsPanel
@onready var _restart_button: Button = %RestartButton
@onready var _main_menu_button: Button = %MainMenuButton
@onready var _options_button: Button = %OptionsButton
@onready var _exit_button: Button = %ExitButton

var _is_open := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("game_menu")
	_restart_button.pressed.connect(_on_restart_pressed)
	_restart_button.visible = not _has_remote_peers()
	_main_menu_button.pressed.connect(_on_main_menu_pressed)
	_options_button.pressed.connect(_on_options_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)
	_options_panel.connect("back_requested", Callable(self, "_on_options_back_requested"))
	_options_panel.connect("keybindings_requested", Callable(self, "_on_keybindings_requested"))
	_keybindings_panel.connect("back_requested", Callable(self, "_on_keybindings_back_requested"))
	_set_open(false, false)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if not _is_open:
			_set_open(true)
		elif _keybindings_panel.visible:
			_on_keybindings_back_requested()
		elif _options_panel.visible:
			_on_options_back_requested()
		else:
			_set_open(false)
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _is_open


func _set_open(value: bool, update_mouse_mode := true) -> void:
	_is_open = value
	_menu_root.visible = value
	_set_options_open(false)
	_apply_single_player_pause_state(value)

	if not update_mouse_mode:
		return

	if value:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		if _restart_button.visible:
			_restart_button.grab_focus()
		else:
			_main_menu_button.grab_focus()
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


func _on_options_pressed() -> void:
	_set_options_open(true)


func _on_options_back_requested() -> void:
	_set_options_open(false)
	_options_button.grab_focus()


func _on_keybindings_requested() -> void:
	_menu_panel.visible = false
	_options_panel.visible = false
	_keybindings_panel.visible = true
	if _keybindings_panel.has_method("focus_first"):
		_keybindings_panel.call("focus_first")


func _on_keybindings_back_requested() -> void:
	_keybindings_panel.visible = false
	_options_panel.visible = true
	if _options_panel.has_method("focus_first"):
		_options_panel.call("focus_first")


func _set_options_open(open: bool) -> void:
	_menu_panel.visible = not open
	_options_panel.visible = open
	_keybindings_panel.visible = false

	if open and _options_panel.has_method("focus_first"):
		_options_panel.call("focus_first")


func _apply_single_player_pause_state(menu_open: bool) -> void:
	if _has_remote_peers():
		if get_tree().paused:
			get_tree().paused = false
		return

	get_tree().paused = menu_open


func _has_remote_peers() -> bool:
	return multiplayer.multiplayer_peer != null and not multiplayer.get_peers().is_empty()
