extends PanelContainer

signal back_requested
signal keybindings_requested

@onready var _debug_force_arrows_check: CheckButton = %DebugForceArrowsCheck
@onready var _bot_debug_check: CheckButton = %BotDebugCheck
@onready var _advanced_hud_check: CheckButton = %AdvancedHudCheck
@onready var _relative_roll_clock_check: CheckButton = %RelativeRollClockCheck
@onready var _global_direction_markers_check: CheckButton = %GlobalDirectionMarkersCheck
@onready var _keybindings_button: Button = %KeyBindingsButton
@onready var _back_button: Button = %OptionsBackButton


func _ready() -> void:
	_debug_force_arrows_check.toggled.connect(_on_debug_force_arrows_toggled)
	_bot_debug_check.toggled.connect(_on_bot_debug_toggled)
	_advanced_hud_check.toggled.connect(_on_advanced_hud_toggled)
	_relative_roll_clock_check.toggled.connect(_on_relative_roll_clock_toggled)
	_global_direction_markers_check.toggled.connect(_on_global_direction_markers_toggled)
	_keybindings_button.pressed.connect(_on_keybindings_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	DisplaySettings.settings_changed.connect(_sync_from_settings)
	_sync_from_settings()


func focus_first() -> void:
	_debug_force_arrows_check.grab_focus()


func _sync_from_settings() -> void:
	_debug_force_arrows_check.set_pressed_no_signal(DisplaySettings.debug_force_arrows_enabled)
	_bot_debug_check.set_pressed_no_signal(DisplaySettings.bot_debug_enabled)
	_advanced_hud_check.set_pressed_no_signal(DisplaySettings.advanced_hud_enabled)
	_relative_roll_clock_check.set_pressed_no_signal(DisplaySettings.relative_roll_clock_enabled)
	_global_direction_markers_check.set_pressed_no_signal(DisplaySettings.global_direction_markers_enabled)


func _on_debug_force_arrows_toggled(button_pressed: bool) -> void:
	DisplaySettings.set_debug_force_arrows_enabled(button_pressed)


func _on_bot_debug_toggled(button_pressed: bool) -> void:
	DisplaySettings.set_bot_debug_enabled(button_pressed)


func _on_advanced_hud_toggled(button_pressed: bool) -> void:
	DisplaySettings.set_advanced_hud_enabled(button_pressed)


func _on_relative_roll_clock_toggled(button_pressed: bool) -> void:
	DisplaySettings.set_relative_roll_clock_enabled(button_pressed)


func _on_global_direction_markers_toggled(button_pressed: bool) -> void:
	DisplaySettings.set_global_direction_markers_enabled(button_pressed)


func _on_keybindings_pressed() -> void:
	keybindings_requested.emit()


func _on_back_pressed() -> void:
	back_requested.emit()
