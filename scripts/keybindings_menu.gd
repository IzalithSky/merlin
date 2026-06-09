extends PanelContainer

signal back_requested

const LISTENING_TEXT := "[press key]"

var _listening_action := ""
var _listening_slot := -1
var _row_buttons: Dictionary = {}

@onready var _action_grid: GridContainer = %ActionGrid
@onready var _back_button: Button = %KeybindingsBackButton


func _ready() -> void:
	_build_rows()
	_back_button.pressed.connect(_on_back_pressed)
	KeybindingsSettings.bindings_changed.connect(_refresh_labels)


func _input(event: InputEvent) -> void:
	if _listening_action.is_empty():
		return

	if not event is InputEventKey:
		return

	if not (event as InputEventKey).pressed or (event as InputEventKey).echo:
		return

	if (event as InputEventKey).physical_keycode == KEY_ESCAPE:
		_stop_listening()
		get_viewport().set_input_as_handled()
		return

	KeybindingsSettings.set_binding(
		_listening_action, _listening_slot,
		(event as InputEventKey).physical_keycode
	)
	_stop_listening()
	get_viewport().set_input_as_handled()


func focus_first() -> void:
	for action in KeybindingsSettings.ACTIONS:
		if _row_buttons.has(action):
			(_row_buttons[action] as Array)[0].grab_focus()
			return


func _build_rows() -> void:
	for action in KeybindingsSettings.ACTIONS:
		var label := Label.new()
		label.text = KeybindingsSettings.ACTION_LABELS.get(action, action)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 17)
		_action_grid.add_child(label)

		var btn1 := Button.new()
		btn1.custom_minimum_size = Vector2(120, 38)
		btn1.add_theme_font_size_override("font_size", 15)
		btn1.pressed.connect(_on_bind_pressed.bind(action, 0))
		_action_grid.add_child(btn1)

		var btn2 := Button.new()
		btn2.custom_minimum_size = Vector2(120, 38)
		btn2.add_theme_font_size_override("font_size", 15)
		btn2.pressed.connect(_on_bind_pressed.bind(action, 1))
		_action_grid.add_child(btn2)

		var clear_btn := Button.new()
		clear_btn.text = "Clear"
		clear_btn.custom_minimum_size = Vector2(60, 38)
		clear_btn.add_theme_font_size_override("font_size", 15)
		clear_btn.pressed.connect(_on_clear_pressed.bind(action))
		_action_grid.add_child(clear_btn)

		_row_buttons[action] = [btn1, btn2, clear_btn]

	_refresh_labels()


func _refresh_labels() -> void:
	for action in KeybindingsSettings.ACTIONS:
		if not _row_buttons.has(action):
			continue

		var slots: Array = KeybindingsSettings.get_bindings(action)
		var btns: Array = _row_buttons[action]

		if _listening_action != action:
			(btns[0] as Button).text = _keycode_label(int(slots[0]))
			(btns[1] as Button).text = _keycode_label(int(slots[1]))


func _keycode_label(physical_keycode: int) -> String:
	if physical_keycode < 0:
		return "---"

	return OS.get_keycode_string(physical_keycode as Key)


func _on_bind_pressed(action: String, slot: int) -> void:
	_stop_listening()
	_listening_action = action
	_listening_slot = slot
	(_row_buttons[action] as Array)[slot].text = LISTENING_TEXT


func _stop_listening() -> void:
	if _listening_action.is_empty():
		return

	_listening_action = ""
	_listening_slot = -1
	_refresh_labels()


func _on_clear_pressed(action: String) -> void:
	if _listening_action == action:
		_stop_listening()

	KeybindingsSettings.clear_action(action)


func _on_back_pressed() -> void:
	_stop_listening()
	back_requested.emit()
