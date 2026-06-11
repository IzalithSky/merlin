extends Node

signal settings_changed

const SAVE_PATH := "user://display_settings.cfg"
const SECTION := "display"
const KEY_DEBUG_FORCE_ARROWS := "debug_force_arrows"
const KEY_BOT_DEBUG := "bot_debug"
const KEY_ADVANCED_HUD := "advanced_hud"
const KEY_RELATIVE_ROLL_CLOCK := "relative_roll_clock"
const KEY_GLOBAL_DIRECTION_MARKERS := "global_direction_markers"
const KEY_MOUSE_SENSITIVITY := "mouse_sensitivity"

var debug_force_arrows_enabled := true
var bot_debug_enabled := true
var advanced_hud_enabled := true
var relative_roll_clock_enabled := true
var global_direction_markers_enabled := true
var mouse_sensitivity := 0.006


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	var config := ConfigFile.new()
	var error := config.load(SAVE_PATH)
	if error != OK:
		debug_force_arrows_enabled = true
		bot_debug_enabled = true
		advanced_hud_enabled = true
		relative_roll_clock_enabled = true
		global_direction_markers_enabled = true
		mouse_sensitivity = 0.006
		return

	debug_force_arrows_enabled = bool(config.get_value(SECTION, KEY_DEBUG_FORCE_ARROWS, true))
	bot_debug_enabled = bool(config.get_value(SECTION, KEY_BOT_DEBUG, true))
	advanced_hud_enabled = bool(config.get_value(SECTION, KEY_ADVANCED_HUD, true))
	relative_roll_clock_enabled = bool(config.get_value(SECTION, KEY_RELATIVE_ROLL_CLOCK, true))
	global_direction_markers_enabled = bool(config.get_value(SECTION, KEY_GLOBAL_DIRECTION_MARKERS, true))
	mouse_sensitivity = clampf(float(config.get_value(SECTION, KEY_MOUSE_SENSITIVITY, 0.006)), 0.001, 0.020)


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value(SECTION, KEY_DEBUG_FORCE_ARROWS, debug_force_arrows_enabled)
	config.set_value(SECTION, KEY_BOT_DEBUG, bot_debug_enabled)
	config.set_value(SECTION, KEY_ADVANCED_HUD, advanced_hud_enabled)
	config.set_value(SECTION, KEY_RELATIVE_ROLL_CLOCK, relative_roll_clock_enabled)
	config.set_value(SECTION, KEY_GLOBAL_DIRECTION_MARKERS, global_direction_markers_enabled)
	config.set_value(SECTION, KEY_MOUSE_SENSITIVITY, mouse_sensitivity)

	var error := config.save(SAVE_PATH)
	if error != OK:
		push_warning("Unable to save display settings: %s" % error_string(error))


func set_debug_force_arrows_enabled(enabled: bool) -> void:
	if debug_force_arrows_enabled == enabled:
		return

	debug_force_arrows_enabled = enabled
	save_settings()
	settings_changed.emit()


func set_bot_debug_enabled(enabled: bool) -> void:
	if bot_debug_enabled == enabled:
		return

	bot_debug_enabled = enabled
	save_settings()
	settings_changed.emit()


func set_advanced_hud_enabled(enabled: bool) -> void:
	if advanced_hud_enabled == enabled:
		return

	advanced_hud_enabled = enabled
	save_settings()
	settings_changed.emit()


func set_relative_roll_clock_enabled(enabled: bool) -> void:
	if relative_roll_clock_enabled == enabled:
		return

	relative_roll_clock_enabled = enabled
	save_settings()
	settings_changed.emit()


func set_global_direction_markers_enabled(enabled: bool) -> void:
	if global_direction_markers_enabled == enabled:
		return

	global_direction_markers_enabled = enabled
	save_settings()
	settings_changed.emit()


func set_mouse_sensitivity(value: float) -> void:
	var clamped := clampf(value, 0.001, 0.020)
	if is_equal_approx(mouse_sensitivity, clamped):
		return

	mouse_sensitivity = clamped
	save_settings()
	settings_changed.emit()
