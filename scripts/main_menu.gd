extends Control

const WORLD_SCENE := "res://scenes/world_0.tscn"

@onready var _new_game_button: Button = %NewGameButton
@onready var _exit_button: Button = %ExitButton


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)
	_new_game_button.grab_focus()


func _on_new_game_pressed() -> void:
	get_tree().change_scene_to_file(WORLD_SCENE)


func _on_exit_pressed() -> void:
	get_tree().quit()
