extends Control

const PLANE_AERO_EDITOR_SCENE := "res://scenes/plane_aero_editor.tscn"
const BOT_DUEL_SCENE := "res://scenes/bot_duel.tscn"

@onready var _new_game_button: Button = %NewGameButton
@onready var _bot_duel_button: Button = %BotDuelButton
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _status_label: Label = %StatusLabel
@onready var _plane_editor_button: Button = %PlaneEditorButton
@onready var _options_button: Button = %OptionsButton
@onready var _exit_button: Button = %ExitButton
@onready var _menu_panel: Control = $CenterContainer/Panel
@onready var _options_panel: Control = %OptionsPanel
@onready var _lobby: Node = get_node("/root/Lobby")


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	_bot_duel_button.pressed.connect(_on_bot_duel_pressed)
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_plane_editor_button.pressed.connect(_on_plane_editor_pressed)
	_options_button.pressed.connect(_on_options_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)
	_options_panel.connect("back_requested", Callable(self, "_on_options_back_requested"))
	_address_edit.text = _lobby.DEFAULT_ADDRESS
	_status_label.text = _lobby.last_error
	_set_options_open(false)
	_new_game_button.grab_focus()


func _on_new_game_pressed() -> void:
	_lobby.start_single_player()


func _on_bot_duel_pressed() -> void:
	get_tree().change_scene_to_file(BOT_DUEL_SCENE)


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


func _on_plane_editor_pressed() -> void:
	get_tree().change_scene_to_file(PLANE_AERO_EDITOR_SCENE)


func _on_options_pressed() -> void:
	_set_options_open(true)


func _on_options_back_requested() -> void:
	_set_options_open(false)
	_options_button.grab_focus()


func _set_options_open(open: bool) -> void:
	_menu_panel.visible = not open
	_options_panel.visible = open

	if open and _options_panel.has_method("focus_first"):
		_options_panel.call("focus_first")
