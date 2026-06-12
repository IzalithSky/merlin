extends RefCounted


static func apply_to_tree(characters: Node) -> void:
	for character in characters.get_children():
		apply_to_character(character)


static func apply_to_character(character: Node) -> void:
	if character == null or not character.is_in_group("plane_character"):
		return

	var plane := character
	plane.debug_force_vectors_enabled = DisplaySettings.debug_force_arrows_enabled

	if DisplaySettings.debug_force_arrows_enabled:
		plane._ensure_force_debug_renderer()

	plane._update_force_debug_renderer_state()

	var bot_pilot = plane.get_bot_pilot()
	if bot_pilot == null:
		return

	bot_pilot.debug_bot_visuals_enabled = DisplaySettings.bot_debug_enabled

	if DisplaySettings.bot_debug_enabled:
		bot_pilot._ensure_bot_debug_renderer()

	bot_pilot._update_bot_debug_renderer_state()


static func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true

	return false
