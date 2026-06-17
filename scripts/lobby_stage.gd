extends Control

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const AERO_TABLES_STORE := preload("res://scripts/plane_aero_tables_store.gd")

@onready var _lobby: Node = get_node("/root/Lobby")
@onready var _players_label: Label = %PlayersLabel
@onready var _status_label: Label = %StatusLabel
@onready var _ready_button: Button = %ReadyButton
@onready var _join_in_progress_check: CheckButton = %JoinInProgressCheck
@onready var _trails_enabled_check: CheckButton = %TrailsEnabledCheck
@onready var _bot_count_spin_box: SpinBox = %BotCountSpinBox
@onready var _preset_option: OptionButton = %PresetOption
@onready var _start_button: Button = %StartButton
@onready var _main_menu_button: Button = %MainMenuButton


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_lobby.lobby_state_changed.connect(_update_players)
	_lobby.session_options_changed.connect(_update_session_options)
	_lobby.status_changed.connect(_update_status)
	_ready_button.pressed.connect(_on_ready_pressed)
	_join_in_progress_check.toggled.connect(_on_join_in_progress_toggled)
	_trails_enabled_check.toggled.connect(_on_trails_enabled_toggled)
	_bot_count_spin_box.value_changed.connect(_on_bot_count_changed)
	_populate_preset_option()
	_preset_option.item_selected.connect(_on_preset_selected)
	_start_button.pressed.connect(_on_start_pressed)
	_main_menu_button.pressed.connect(_on_main_menu_pressed)
	_update_players(_lobby.players)
	_update_session_options(_lobby.is_game_in_progress, _lobby.allow_join_in_progress, _lobby.bot_count, _lobby.trails_enabled)
	_update_status(_lobby.last_error)
	_ready_button.grab_focus()


func _update_players(players: Dictionary) -> void:
	var local_peer_id: int = _lobby.get_local_peer_id()
	var peer_ids := players.keys()
	peer_ids.sort()

	var lines: Array[String] = []
	for peer_id in peer_ids:
		var player: Dictionary = players[peer_id]
		var labels: Array[String] = []

		if peer_id == 1:
			labels.append("host")
		if peer_id == local_peer_id:
			labels.append("you")

		var ready_text := "ready" if bool(player.get("ready", false)) else "not ready"
		var suffix := ""
		if not labels.is_empty():
			suffix = " (%s)" % ", ".join(labels)

		lines.append("%s%s - %s" % [String(player.get("name", "Player %d" % peer_id)), suffix, ready_text])

	_players_label.text = "\n".join(lines) if not lines.is_empty() else "Waiting for players..."

	var local_player: Dictionary = players.get(local_peer_id, {})
	var is_ready := bool(local_player.get("ready", false))
	_ready_button.text = "Unready" if is_ready else "Ready"
	_start_button.visible = _lobby.is_server_peer()
	_start_button.disabled = not _lobby.is_server_peer()
	_join_in_progress_check.visible = _lobby.is_server_peer()
	_join_in_progress_check.disabled = not _lobby.is_server_peer()
	_trails_enabled_check.disabled = not _lobby.is_server_peer()
	_bot_count_spin_box.editable = _lobby.is_server_peer()


func _update_session_options(_is_game_in_progress: bool, allow_join_in_progress: bool, bot_count: int, trails_enabled: bool) -> void:
	_join_in_progress_check.button_pressed = allow_join_in_progress
	_trails_enabled_check.set_pressed_no_signal(trails_enabled)
	_bot_count_spin_box.set_value_no_signal(bot_count)


func _update_status(message: String) -> void:
	_status_label.text = message


func _on_ready_pressed() -> void:
	var local_peer_id: int = _lobby.get_local_peer_id()
	var local_player: Dictionary = _lobby.players.get(local_peer_id, {})
	_lobby.set_local_ready(not bool(local_player.get("ready", false)))


func _on_join_in_progress_toggled(button_pressed: bool) -> void:
	_lobby.set_allow_join_in_progress(button_pressed)


func _on_trails_enabled_toggled(button_pressed: bool) -> void:
	_lobby.set_trails_enabled(button_pressed)


func _populate_preset_option() -> void:
	_preset_option.clear()
	var active: Dictionary = AERO_TABLES_STORE.load_payload()
	var active_source := String(active.get("source", ""))
	var active_id := String(active.get("id", ""))
	var select_index := 0
	var index := 0
	for entry: Dictionary in AERO_TABLES_STORE.list_presets():
		var label: String = entry["name"]
		if entry["source"] == AERO_TABLES_STORE.SOURCE_BUILTIN:
			label += "  (built-in)"
		_preset_option.add_item(label)
		_preset_option.set_item_metadata(index, entry)
		if entry["source"] == active_source and entry["id"] == active_id:
			select_index = index
		index += 1
	if _preset_option.item_count > 0:
		_preset_option.select(select_index)


func _on_preset_selected(index: int) -> void:
	var meta: Variant = _preset_option.get_item_metadata(index)
	if not meta is Dictionary:
		return
	var entry: Dictionary = meta
	var payload: Dictionary = AERO_TABLES_STORE.load_preset(entry["source"], entry["id"])
	if payload.is_empty():
		return
	AERO_TABLES_STORE.save_payload(payload)


func _on_bot_count_changed(value: float) -> void:
	_lobby.set_bot_count(int(round(value)))


func _on_start_pressed() -> void:
	var error: Error = _lobby.start_game()
	if error != OK:
		_update_status(_lobby.last_error)


func _on_main_menu_pressed() -> void:
	_lobby.disconnect_session()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
