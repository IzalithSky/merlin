extends PanelContainer

signal back_requested

const DIGITAL_LISTENING_TEXT := "[press key]"
const ANALOG_LISTENING_TEXT := "[move axis]"
const ANALOG_BIND_THRESHOLD := 0.5

var _listening_action := ""
var _listening_slot := -1
var _row_buttons: Dictionary = {}
var _listening_analog_action := ""
var _analog_rows: Dictionary = {}

@onready var _action_grid: GridContainer = %ActionGrid
@onready var _back_button: Button = %KeybindingsBackButton
@onready var _reset_button: Button = %KeybindingsResetButton


func _ready() -> void:
	_build_rows()
	_back_button.pressed.connect(_on_back_pressed)
	_reset_button.pressed.connect(_on_reset_pressed)
	KeybindingsSettings.bindings_changed.connect(_refresh_labels)
	set_process(true)


func _input(event: InputEvent) -> void:
	if not _listening_analog_action.is_empty():
		if event is InputEventKey:
			if not (event as InputEventKey).pressed or (event as InputEventKey).echo:
				return
			if (event as InputEventKey).physical_keycode == KEY_ESCAPE:
				_stop_listening()
				get_viewport().set_input_as_handled()
			return

		if event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) >= ANALOG_BIND_THRESHOLD:
			var existing_binding := KeybindingsSettings.get_analog_binding(_listening_analog_action)
			KeybindingsSettings.set_analog_binding(
				_listening_analog_action,
				{
					"guid": Input.get_joy_guid((event as InputEventJoypadMotion).device),
					"device_name": Input.get_joy_name((event as InputEventJoypadMotion).device),
					"axis": int((event as InputEventJoypadMotion).axis),
					"invert": bool(existing_binding.get("invert", false)),
				}
			)
			_stop_listening()
			get_viewport().set_input_as_handled()
		return

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


func _process(_delta: float) -> void:
	for action in KeybindingsSettings.ANALOG_ACTIONS:
		if not _analog_rows.has(action):
			continue
		var row: Dictionary = _analog_rows[action]
		(row["meter"] as ProgressBar).value = KeybindingsSettings.get_analog_value(action) * 100.0


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

	_build_analog_rows()
	_refresh_labels()


func _build_analog_rows() -> void:
	var section_label := Label.new()
	section_label.text = "Analog Axes  —  move an axis to bind, use invert if needed"
	section_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section_label.add_theme_font_size_override("font_size", 17)
	_action_grid.add_child(section_label)

	for _column in 3:
		_action_grid.add_child(Control.new())

	for action in KeybindingsSettings.ANALOG_ACTIONS:
		var label := Label.new()
		label.text = KeybindingsSettings.ANALOG_LABELS.get(action, action)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 17)
		_action_grid.add_child(label)

		var bind_button := Button.new()
		bind_button.custom_minimum_size = Vector2(160, 38)
		bind_button.add_theme_font_size_override("font_size", 15)
		bind_button.pressed.connect(_on_analog_bind_pressed.bind(action))
		_action_grid.add_child(bind_button)

		var analog_controls := HBoxContainer.new()
		analog_controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		analog_controls.alignment = BoxContainer.ALIGNMENT_BEGIN

		var invert_toggle := CheckButton.new()
		invert_toggle.text = "Invert"
		invert_toggle.add_theme_font_size_override("font_size", 14)
		invert_toggle.toggled.connect(_on_analog_invert_toggled.bind(action))
		analog_controls.add_child(invert_toggle)

		var meter := ProgressBar.new()
		meter.custom_minimum_size = Vector2(160, 0)
		meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		meter.min_value = -100.0
		meter.max_value = 100.0
		meter.show_percentage = false
		analog_controls.add_child(meter)

		_action_grid.add_child(analog_controls)

		var clear_button := Button.new()
		clear_button.text = "Clear"
		clear_button.custom_minimum_size = Vector2(60, 38)
		clear_button.add_theme_font_size_override("font_size", 15)
		clear_button.pressed.connect(_on_analog_clear_pressed.bind(action))
		_action_grid.add_child(clear_button)

		_analog_rows[action] = {
			"button": bind_button,
			"invert": invert_toggle,
			"meter": meter,
			"clear": clear_button,
		}


func _refresh_labels() -> void:
	for action in KeybindingsSettings.ACTIONS:
		if not _row_buttons.has(action):
			continue

		var slots: Array = KeybindingsSettings.get_bindings(action)
		var btns: Array = _row_buttons[action]

		if _listening_action != action:
			(btns[0] as Button).text = _binding_label(slots[0])
			(btns[1] as Button).text = _binding_label(slots[1])

	for action in KeybindingsSettings.ANALOG_ACTIONS:
		if not _analog_rows.has(action):
			continue
		var row: Dictionary = _analog_rows[action]
		var binding := KeybindingsSettings.get_analog_binding(action)
		if _listening_analog_action != action:
			(row["button"] as Button).text = _analog_binding_label(binding)
		(row["invert"] as CheckButton).set_pressed_no_signal(bool(binding.get("invert", false)))


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


func _analog_binding_label(binding: Dictionary) -> String:
	var axis_index := int(binding.get("axis", -1))
	if axis_index < 0:
		return "---"

	var device_name := str(binding.get("device_name", "Joypad"))
	return "%s / %s" % [device_name.strip_edges(), KeybindingsSettings.get_analog_axis_label(axis_index)]


func _on_bind_pressed(action: String, slot: int) -> void:
	_stop_listening()
	_listening_action = action
	_listening_slot = slot
	(_row_buttons[action] as Array)[slot].text = DIGITAL_LISTENING_TEXT


func _on_analog_bind_pressed(action: String) -> void:
	_stop_listening()
	_listening_analog_action = action
	(_analog_rows[action] as Dictionary)["button"].text = ANALOG_LISTENING_TEXT


func _stop_listening() -> void:
	_listening_action = ""
	_listening_slot = -1
	_listening_analog_action = ""
	_refresh_labels()


func _on_clear_pressed(action: String) -> void:
	if _listening_action == action:
		_stop_listening()

	KeybindingsSettings.clear_action(action)


func _on_analog_clear_pressed(action: String) -> void:
	if _listening_analog_action == action:
		_stop_listening()

	KeybindingsSettings.clear_analog_binding(action)


func _on_analog_invert_toggled(button_pressed: bool, action: String) -> void:
	KeybindingsSettings.set_analog_inverted(action, button_pressed)


func _on_reset_pressed() -> void:
	_stop_listening()
	KeybindingsSettings.reset_to_defaults()


func _on_back_pressed() -> void:
	_stop_listening()
	back_requested.emit()
