extends Node

signal bindings_changed

const SAVE_PATH := "user://keybindings.cfg"
const SECTION := "bindings"
const MAX_BINDINGS := 2

const ACTIONS: Array[String] = [
	"pitch_up", "pitch_down",
	"yaw_left", "yaw_right",
	"roll_left", "roll_right",
	"throttle_up", "throttle_down",
	"relative_roll_left", "relative_roll_right",
	"target_select", "target_deselect",
	"target_cycle_next", "target_cycle_prev",
	"fire_missile",
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
	"relative_roll_left": "Relative Roll Left",
	"relative_roll_right": "Relative Roll Right",
	"target_select": "Target Select",
	"target_deselect": "Target Deselect",
	"target_cycle_next": "Target Next",
	"target_cycle_prev": "Target Prev",
	"fire_missile": "Fire Missile",
}

var _bindings: Dictionary = {}


func _ready() -> void:
	_load_defaults()
	load_bindings()
	_apply_to_input_map()


func get_bindings(action: String) -> Array:
	return (_bindings.get(action, [-1, -1]) as Array).duplicate()


func set_binding(action: String, slot: int, physical_keycode: int) -> void:
	if not action in ACTIONS:
		return
	if slot < 0 or slot >= MAX_BINDINGS:
		return

	if not _bindings.has(action):
		_bindings[action] = [-1, -1]

	_bindings[action][slot] = physical_keycode
	_apply_to_input_map()
	save_bindings()
	bindings_changed.emit()


func clear_action(action: String) -> void:
	if not action in ACTIONS:
		return

	_bindings[action] = [-1, -1]
	_apply_to_input_map()
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
			_bindings[action] = [int((saved as Array)[0]), int((saved as Array)[1])]


func save_bindings() -> void:
	var config := ConfigFile.new()
	for action in ACTIONS:
		config.set_value(SECTION, action, _bindings.get(action, [-1, -1]))

	var error := config.save(SAVE_PATH)
	if error != OK:
		push_warning("Unable to save keybindings: %s" % error_string(error))


func _load_defaults() -> void:
	_bindings = _make_defaults()


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
		"relative_roll_left": [KEY_A, -1],
		"relative_roll_right": [KEY_D, -1],
		"target_select": [KEY_T, -1],
		"target_deselect": [KEY_G, -1],
		"target_cycle_next": [KEY_Y, -1],
		"target_cycle_prev": [-1, -1],
		"fire_missile": [KEY_F, -1],
	}


func _apply_to_input_map() -> void:
	for action in ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		else:
			InputMap.action_erase_events(action)

		var slots: Array = _bindings.get(action, [-1, -1])
		for keycode in slots:
			if int(keycode) < 0:
				continue
			var event := InputEventKey.new()
			event.physical_keycode = int(keycode) as Key
			InputMap.action_add_event(action, event)
