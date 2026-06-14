extends Node

signal bindings_changed

const SAVE_PATH := "user://keybindings.cfg"
const SECTION := "bindings"
const ANALOG_SECTION := "analog_bindings"
const MAX_BINDINGS := 2
const ANALOG_DEADZONE := 0.08

const ACTIONS: Array[String] = [
	"pitch_up", "pitch_down",
	"yaw_left", "yaw_right",
	"roll_left", "roll_right",
	"throttle_up", "throttle_down",
	"limiter_override",
	"toggle_pitch_assist",
	"toggle_stabilization_assist",
	"toggle_input_decay",
	"relative_roll_left", "relative_roll_right",
	"target_select", "target_deselect",
	"target_cycle_next", "target_cycle_prev",
	"fire_missile",
	"fire_autocannon",
	"toggle_camera_view",
]

const ACTION_LABELS: Dictionary = {
	"pitch_up": "Pitch Up",
	"pitch_down": "Pitch Down",
	"yaw_left": "Yaw Left",
	"yaw_right": "Yaw Right",
	"roll_left": "Roll Left",
	"roll_right": "Roll Right",
	"throttle_up": "Throttle Up",
	"throttle_down": "Throttle Down",
	"limiter_override": "Limiter Override",
	"toggle_pitch_assist": "Pitch Assist Toggle",
	"toggle_stabilization_assist": "Stabilization Toggle",
	"toggle_input_decay": "Input Decay Toggle",
	"relative_roll_left": "Relative Roll Left",
	"relative_roll_right": "Relative Roll Right",
	"target_select": "Target Select",
	"target_deselect": "Target Deselect",
	"target_cycle_next": "Target Next",
	"target_cycle_prev": "Target Prev",
	"fire_missile": "Fire Missile",
	"fire_autocannon": "Fire Autocannon",
	"toggle_camera_view": "Camera View",
}

const ANALOG_ACTIONS: Array[String] = [
	"pitch_axis",
	"yaw_axis",
	"roll_axis",
]

const ANALOG_LABELS: Dictionary = {
	"pitch_axis": "Pitch Axis",
	"yaw_axis": "Yaw Axis",
	"roll_axis": "Roll Axis",
}

var _bindings: Dictionary = {}
var _analog_bindings: Dictionary = {}


func _ready() -> void:
	_load_defaults()
	load_bindings()
	_apply_to_input_map()


func get_bindings(action: String) -> Array:
	return (_bindings.get(action, [-1, -1]) as Array).duplicate(true)


func get_analog_binding(action: String) -> Dictionary:
	return (_analog_bindings.get(action, _make_default_analog_binding()) as Dictionary).duplicate(true)


func set_binding(action: String, slot: int, binding: Variant) -> void:
	if not action in ACTIONS:
		return
	if slot < 0 or slot >= MAX_BINDINGS:
		return

	if not _bindings.has(action):
		_bindings[action] = [-1, -1]

	_bindings[action][slot] = _normalize_binding(binding)
	_apply_to_input_map()
	save_bindings()
	bindings_changed.emit()


func set_analog_binding(action: String, binding: Dictionary) -> void:
	if not action in ANALOG_ACTIONS:
		return

	_analog_bindings[action] = _normalize_analog_binding(binding)
	save_bindings()
	bindings_changed.emit()


func set_analog_inverted(action: String, inverted: bool) -> void:
	if not action in ANALOG_ACTIONS:
		return

	var binding := get_analog_binding(action)
	binding["invert"] = inverted
	_analog_bindings[action] = _normalize_analog_binding(binding)
	save_bindings()
	bindings_changed.emit()


func clear_action(action: String) -> void:
	if not action in ACTIONS:
		return

	_bindings[action] = [-1, -1]
	_apply_to_input_map()
	save_bindings()
	bindings_changed.emit()


func clear_analog_binding(action: String) -> void:
	if not action in ANALOG_ACTIONS:
		return

	_analog_bindings[action] = _make_default_analog_binding()
	save_bindings()
	bindings_changed.emit()


func reset_to_defaults() -> void:
	_load_defaults()
	_apply_to_input_map()
	save_bindings()
	bindings_changed.emit()


func load_bindings() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return

	for action in ACTIONS:
		if not config.has_section_key(SECTION, action):
			continue
		var saved: Variant = config.get_value(SECTION, action)
		if saved is Array and (saved as Array).size() == MAX_BINDINGS:
			_bindings[action] = [
				_normalize_binding((saved as Array)[0]),
				_normalize_binding((saved as Array)[1])
			]

	for action in ANALOG_ACTIONS:
		if not config.has_section_key(ANALOG_SECTION, action):
			continue
		var saved_analog: Variant = config.get_value(ANALOG_SECTION, action)
		_analog_bindings[action] = _normalize_analog_binding(saved_analog)


func save_bindings() -> void:
	var config := ConfigFile.new()
	for action in ACTIONS:
		config.set_value(SECTION, action, _bindings.get(action, [-1, -1]))
	for action in ANALOG_ACTIONS:
		config.set_value(ANALOG_SECTION, action, _analog_bindings.get(action, _make_default_analog_binding()))

	var error := config.save(SAVE_PATH)
	if error != OK:
		push_warning("Unable to save keybindings: %s" % error_string(error))


func _load_defaults() -> void:
	_bindings = _make_defaults()
	_analog_bindings = _make_analog_defaults()


func _make_defaults() -> Dictionary:
	return {
		"pitch_up": [KEY_W, -1],
		"pitch_down": [KEY_S, -1],
		"yaw_left": [KEY_Q, -1],
		"yaw_right": [KEY_E, -1],
		"roll_left": [KEY_Z, -1],
		"roll_right": [KEY_X, -1],
		"throttle_up": [KEY_SPACE, -1],
		"throttle_down": [KEY_SHIFT, -1],
		"limiter_override": [KEY_CTRL, -1],
		"toggle_pitch_assist": [KEY_O, -1],
		"toggle_stabilization_assist": [KEY_P, -1],
		"toggle_input_decay": [KEY_I, -1],
		"relative_roll_left": [KEY_A, -1],
		"relative_roll_right": [KEY_D, -1],
		"target_select": [KEY_R, -1],
		"target_deselect": [KEY_G, -1],
		"target_cycle_next": [KEY_Y, -1],
		"target_cycle_prev": [-1, -1],
		"fire_missile": [_mouse_binding(MOUSE_BUTTON_RIGHT), -1],
		"fire_autocannon": [_mouse_binding(MOUSE_BUTTON_LEFT), -1],
		"toggle_camera_view": [KEY_C, -1],
	}


func _make_analog_defaults() -> Dictionary:
	var defaults := {}
	for action in ANALOG_ACTIONS:
		defaults[action] = _make_default_analog_binding()
	return defaults


func _make_default_analog_binding() -> Dictionary:
	return {
		"guid": "",
		"device_name": "",
		"axis": -1,
		"invert": false,
	}


func _apply_to_input_map() -> void:
	for action in ACTIONS:
		if InputMap.has_action(action):
			InputMap.action_erase_events(action)
		else:
			push_warning("Input action missing from project settings: %s" % action)
			continue

		var slots: Array = _bindings.get(action, [-1, -1])
		for binding in slots:
			var normalized: Variant = _normalize_binding(binding)
			if normalized is int and int(normalized) < 0:
				continue
			var event: InputEvent = _binding_to_input_event(normalized)
			if event != null:
				InputMap.action_add_event(action, event)


func _normalize_binding(binding: Variant) -> Variant:
	if binding is Dictionary:
		var dict_binding := binding as Dictionary
		var binding_type := str(dict_binding.get("type", ""))
		if binding_type == "mouse":
			return {
				"type": "mouse",
				"button_index": int(dict_binding.get("button_index", -1))
			}
	if binding is int:
		return int(binding)
	return -1


func _normalize_analog_binding(binding: Variant) -> Dictionary:
	var normalized := _make_default_analog_binding()
	if not (binding is Dictionary):
		return normalized

	var analog_binding := binding as Dictionary
	normalized["guid"] = str(analog_binding.get("guid", ""))
	normalized["device_name"] = str(analog_binding.get("device_name", ""))
	normalized["axis"] = int(analog_binding.get("axis", -1))
	normalized["invert"] = bool(analog_binding.get("invert", false))
	return normalized


func _binding_to_input_event(binding: Variant) -> InputEvent:
	if binding is int:
		var keycode := int(binding)
		if keycode < 0:
			return null
		var key_event := InputEventKey.new()
		key_event.physical_keycode = keycode as Key
		return key_event

	if binding is Dictionary and str((binding as Dictionary).get("type", "")) == "mouse":
		var mouse_event := InputEventMouseButton.new()
		mouse_event.button_index = int((binding as Dictionary).get("button_index", -1)) as MouseButton
		return mouse_event

	return null


func _mouse_binding(button_index: MouseButton) -> Dictionary:
	return {
		"type": "mouse",
		"button_index": int(button_index)
	}


func is_analog_axis_bound(action: String) -> bool:
	if not action in ANALOG_ACTIONS:
		return false
	var binding := get_analog_binding(action)
	if int(binding.get("axis", -1)) < 0:
		return false
	return _find_bound_joypad_id(binding) >= 0


func get_analog_value(action: String) -> float:
	if not action in ANALOG_ACTIONS:
		return 0.0

	var binding := get_analog_binding(action)
	var axis_index := int(binding.get("axis", -1))
	if axis_index < 0:
		return 0.0

	var device_id := _find_bound_joypad_id(binding)
	if device_id < 0:
		return 0.0

	var value := Input.get_joy_axis(device_id, axis_index)
	if bool(binding.get("invert", false)):
		value = -value
	if absf(value) < ANALOG_DEADZONE:
		return 0.0
	return clampf(value, -1.0, 1.0)


func get_analog_axis_label(axis_index: int) -> String:
	match axis_index:
		JOY_AXIS_LEFT_X:
			return "Left X"
		JOY_AXIS_LEFT_Y:
			return "Left Y"
		JOY_AXIS_RIGHT_X:
			return "Right X"
		JOY_AXIS_RIGHT_Y:
			return "Right Y"
		JOY_AXIS_TRIGGER_LEFT:
			return "Trigger L"
		JOY_AXIS_TRIGGER_RIGHT:
			return "Trigger R"
		_:
			return "Axis %d" % axis_index


func _find_bound_joypad_id(binding: Dictionary) -> int:
	var target_guid := str(binding.get("guid", ""))
	var target_name := str(binding.get("device_name", ""))
	var connected := Input.get_connected_joypads()

	if not target_guid.is_empty():
		for device_id_variant in connected:
			var device_id := int(device_id_variant)
			if Input.get_joy_guid(device_id) == target_guid:
				return device_id

	if not target_name.is_empty():
		for device_id_variant in connected:
			var device_id := int(device_id_variant)
			if Input.get_joy_name(device_id) == target_name:
				return device_id

	return -1
