extends PanelContainer

signal back_requested
signal keybindings_requested

@onready var _debug_force_arrows_check: CheckButton = %DebugForceArrowsCheck
@onready var _bot_debug_check: CheckButton = %BotDebugCheck
@onready var _advanced_hud_check: CheckButton = %AdvancedHudCheck
@onready var _relative_roll_clock_check: CheckButton = %RelativeRollClockCheck
@onready var _global_direction_markers_check: CheckButton = %GlobalDirectionMarkersCheck
@onready var _visual_trails_check: CheckButton = %VisualTrailsCheck
@onready var _mouse_sensitivity_slider: HSlider = %MouseSensitivitySlider
@onready var _mouse_sensitivity_edit: LineEdit = %MouseSensitivityEdit
@onready var _master_volume_slider: HSlider = %MasterVolumeSlider
@onready var _keybindings_button: Button = %KeyBindingsButton
@onready var _back_button: Button = %OptionsBackButton


func _ready() -> void:
	_debug_force_arrows_check.toggled.connect(_on_debug_force_arrows_toggled)
	_bot_debug_check.toggled.connect(_on_bot_debug_toggled)
	_advanced_hud_check.toggled.connect(_on_advanced_hud_toggled)
	_relative_roll_clock_check.toggled.connect(_on_relative_roll_clock_toggled)
	_global_direction_markers_check.toggled.connect(_on_global_direction_markers_toggled)
	_visual_trails_check.toggled.connect(_on_visual_trails_toggled)
	_mouse_sensitivity_slider.value_changed.connect(_on_mouse_sensitivity_slider_changed)
	_mouse_sensitivity_edit.text_submitted.connect(_on_mouse_sensitivity_edit_submitted)
	_mouse_sensitivity_edit.focus_exited.connect(_on_mouse_sensitivity_edit_focus_exited)
	_master_volume_slider.value_changed.connect(_on_master_volume_slider_changed)
	_keybindings_button.pressed.connect(_on_keybindings_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	DisplaySettings.settings_changed.connect(_sync_from_settings)
	_sync_from_settings()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_on_back_pressed()
		get_viewport().set_input_as_handled()


func focus_first() -> void:
	_debug_force_arrows_check.grab_focus()


func _sync_from_settings() -> void:
	_debug_force_arrows_check.set_pressed_no_signal(DisplaySettings.debug_force_arrows_enabled)
	_bot_debug_check.set_pressed_no_signal(DisplaySettings.bot_debug_enabled)
	_advanced_hud_check.set_pressed_no_signal(DisplaySettings.advanced_hud_enabled)
	_relative_roll_clock_check.set_pressed_no_signal(DisplaySettings.relative_roll_clock_enabled)
	_global_direction_markers_check.set_pressed_no_signal(DisplaySettings.global_direction_markers_enabled)
	_visual_trails_check.set_pressed_no_signal(DisplaySettings.visual_trails_enabled)
	var display_val := int(round(DisplaySettings.mouse_sensitivity * 1000.0))
	_mouse_sensitivity_slider.set_value_no_signal(float(display_val))
	_mouse_sensitivity_edit.text = str(display_val)
	_master_volume_slider.set_value_no_signal(DisplaySettings.master_volume * 100.0)


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


func _on_visual_trails_toggled(button_pressed: bool) -> void:
	DisplaySettings.set_visual_trails_enabled(button_pressed)


func _on_mouse_sensitivity_slider_changed(value: float) -> void:
	_mouse_sensitivity_edit.text = str(int(value))
	DisplaySettings.set_mouse_sensitivity(value / 1000.0)


func _on_mouse_sensitivity_edit_submitted(_text: String) -> void:
	_apply_sensitivity_from_edit()
	_mouse_sensitivity_edit.release_focus()


func _on_mouse_sensitivity_edit_focus_exited() -> void:
	_apply_sensitivity_from_edit()


func _apply_sensitivity_from_edit() -> void:
	var v := _mouse_sensitivity_edit.text.to_int()
	v = clampi(v, 1, 20)
	_mouse_sensitivity_slider.set_value_no_signal(float(v))
	_mouse_sensitivity_edit.text = str(v)
	DisplaySettings.set_mouse_sensitivity(float(v) / 1000.0)


func _on_master_volume_slider_changed(value: float) -> void:
	DisplaySettings.set_master_volume(value / 100.0)


func _on_keybindings_pressed() -> void:
	keybindings_requested.emit()


func _on_back_pressed() -> void:
	back_requested.emit()
