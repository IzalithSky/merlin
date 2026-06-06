extends Node

signal settings_changed

const SAVE_PATH := "user://display_settings.cfg"
const SECTION := "display"
const KEY_DEBUG_FORCE_ARROWS := "debug_force_arrows"
const KEY_BOT_DEBUG := "bot_debug"
const KEY_ADVANCED_HUD := "advanced_hud"

var debug_force_arrows_enabled := true
var bot_debug_enabled := true
var advanced_hud_enabled := true


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	var config := ConfigFile.new()
	var error := config.load(SAVE_PATH)
	if error != OK:
		debug_force_arrows_enabled = true
		bot_debug_enabled = true
		advanced_hud_enabled = true
		return

	debug_force_arrows_enabled = bool(config.get_value(SECTION, KEY_DEBUG_FORCE_ARROWS, true))
	bot_debug_enabled = bool(config.get_value(SECTION, KEY_BOT_DEBUG, true))
	advanced_hud_enabled = bool(config.get_value(SECTION, KEY_ADVANCED_HUD, true))


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value(SECTION, KEY_DEBUG_FORCE_ARROWS, debug_force_arrows_enabled)
	config.set_value(SECTION, KEY_BOT_DEBUG, bot_debug_enabled)
	config.set_value(SECTION, KEY_ADVANCED_HUD, advanced_hud_enabled)

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
