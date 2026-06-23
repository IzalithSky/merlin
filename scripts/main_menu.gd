extends Control

const PLANE_AERO_EDITOR_SCENE := "res://scenes/plane_aero_editor.tscn"
const AERO_TABLES_STORE := preload("res://scripts/plane_aero_tables_store.gd")
const BOT_DUEL_SCENE := "res://scenes/bot_duel.tscn"
const BOT_CHASE_DEBUG_SCENE := "res://scenes/bot_chase_debug.tscn"

@onready var _preset_option: OptionButton = %PresetOption
@onready var _new_game_button: Button = %NewGameButton
@onready var _bot_duel_button: Button = %BotDuelButton
@onready var _bot_chase_debug_button: Button = %BotChaseDebugButton
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _status_label: Label = %StatusLabel
@onready var _plane_editor_button: Button = %PlaneEditorButton
@onready var _options_button: Button = %OptionsButton
@onready var _exit_button: Button = %ExitButton
@onready var _menu_panel: Control = $CenterContainer/Panel
@onready var _options_panel: Control = %OptionsPanel
@onready var _keybindings_panel: Control = %KeybindingsPanel
@onready var _lobby: Node = get_node("/root/Lobby")


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_populate_preset_option(_preset_option)
	_preset_option.item_selected.connect(_on_preset_selected)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	_bot_duel_button.pressed.connect(_on_bot_duel_pressed)
	_bot_chase_debug_button.pressed.connect(_on_bot_chase_debug_pressed)
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_plane_editor_button.pressed.connect(_on_plane_editor_pressed)
	_options_button.pressed.connect(_on_options_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)
	_options_panel.connect("back_requested", Callable(self, "_on_options_back_requested"))
	_options_panel.connect("keybindings_requested", Callable(self, "_on_keybindings_requested"))
	_keybindings_panel.connect("back_requested", Callable(self, "_on_keybindings_back_requested"))
	_address_edit.text = _lobby.DEFAULT_ADDRESS
	_status_label.text = _lobby.last_error
	_set_options_open(false)
	_new_game_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if _keybindings_panel.visible:
			_on_keybindings_back_requested()
			get_viewport().set_input_as_handled()
			return
		if _options_panel.visible:
			_on_options_back_requested()
			get_viewport().set_input_as_handled()


func _populate_preset_option(option: OptionButton) -> void:
	option.clear()
	var active: Dictionary = AERO_TABLES_STORE.load_payload()
	var active_source := String(active.get("source", ""))
	var active_id := String(active.get("id", ""))
	var select_index := 0
	var index := 0
	for entry: Dictionary in AERO_TABLES_STORE.list_presets():
		var label: String = entry["name"]
		if entry["source"] == AERO_TABLES_STORE.SOURCE_BUILTIN:
			label += "  (built-in)"
		option.add_item(label)
		option.set_item_metadata(index, entry)
		if entry["source"] == active_source and entry["id"] == active_id:
			select_index = index
		index += 1
	if option.item_count > 0:
		option.select(select_index)


func _on_preset_selected(index: int) -> void:
	var meta: Variant = _preset_option.get_item_metadata(index)
	if not meta is Dictionary:
		return
	var entry: Dictionary = meta
	var payload: Dictionary = AERO_TABLES_STORE.load_preset(entry["source"], entry["id"])
	if payload.is_empty():
		return
	AERO_TABLES_STORE.save_payload(payload)


func _on_new_game_pressed() -> void:
	_lobby.start_single_player()


func _on_bot_duel_pressed() -> void:
	get_tree().change_scene_to_file(BOT_DUEL_SCENE)


func _on_bot_chase_debug_pressed() -> void:
	get_tree().change_scene_to_file(BOT_CHASE_DEBUG_SCENE)


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
