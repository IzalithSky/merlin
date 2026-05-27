extends Control

@onready var _new_game_button: Button = %NewGameButton
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _status_label: Label = %StatusLabel
@onready var _exit_button: Button = %ExitButton
@onready var _lobby: Node = get_node("/root/Lobby")


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)
	_address_edit.text = _lobby.DEFAULT_ADDRESS
	_status_label.text = _lobby.last_error
	_new_game_button.grab_focus()


func _on_new_game_pressed() -> void:
	_lobby.start_single_player()


func _on_host_pressed() -> void:
	var error: Error = _lobby.host()
	if error != OK:
		_status_label.text = _lobby.last_error


func _on_join_pressed() -> void:
	var error: Error = _lobby.join(_address_edit.text)
	_status_label.text = _lobby.last_error
	if error != OK:
		_join_button.grab_focus()


func _on_exit_pressed() -> void:
	get_tree().quit()
