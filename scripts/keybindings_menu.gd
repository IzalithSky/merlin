extends PanelContainer

signal back_requested

const LISTENING_TEXT := "[press key]"

var _listening_action := ""
var _listening_slot := -1
var _row_buttons: Dictionary = {}

@onready var _action_grid: GridContainer = %ActionGrid
@onready var _back_button: Button = %KeybindingsBackButton
@onready var _reset_button: Button = %KeybindingsResetButton


func _ready() -> void:
	_build_rows()
	_back_button.pressed.connect(_on_back_pressed)
	_reset_button.pressed.connect(_on_reset_pressed)
	KeybindingsSettings.bindings_changed.connect(_refresh_labels)


func _input(event: InputEvent) -> void:
	if _listening_action.is_empty():
		return

	if event is InputEventKey:
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
		return

	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		KeybindingsSettings.set_binding(
			_listening_action, _listening_slot,
			{
				"type": "mouse",
				"button_index": int((event as InputEventMouseButton).button_index)
			}
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
			(btns[0] as Button).text = _binding_label(slots[0])
			(btns[1] as Button).text = _binding_label(slots[1])


func _binding_label(binding: Variant) -> String:
	if binding is int:
		var physical_keycode := int(binding)
		if physical_keycode < 0:
			return "---"
		return OS.get_keycode_string(physical_keycode as Key)

	if binding is Dictionary and str((binding as Dictionary).get("type", "")) == "mouse":
		match int((binding as Dictionary).get("button_index", -1)):
			MOUSE_BUTTON_LEFT:
				return "LMB"
			MOUSE_BUTTON_RIGHT:
				return "RMB"
			MOUSE_BUTTON_MIDDLE:
				return "MMB"
			_:
				return "Mouse %d" % int((binding as Dictionary).get("button_index", -1))

	return "---"


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


func _on_reset_pressed() -> void:
	_stop_listening()
	KeybindingsSettings.reset_to_defaults()


func _on_back_pressed() -> void:
	_stop_listening()
	back_requested.emit()
