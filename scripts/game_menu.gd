extends CanvasLayer

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

@onready var _menu_root: Control = %MenuRoot
@onready var _restart_button: Button = %RestartButton
@onready var _main_menu_button: Button = %MainMenuButton
@onready var _exit_button: Button = %ExitButton

var _is_open := false


func _ready() -> void:
	add_to_group("game_menu")
	_restart_button.pressed.connect(_on_restart_pressed)
	_main_menu_button.pressed.connect(_on_main_menu_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)
	_set_open(false)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_set_open(not _is_open)
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _is_open


func _set_open(value: bool) -> void:
	_is_open = value
	_menu_root.visible = value

	if value:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_restart_button.grab_focus()
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _on_restart_pressed() -> void:
	get_tree().reload_current_scene()


func _on_main_menu_pressed() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func _on_exit_pressed() -> void:
	get_tree().quit()
