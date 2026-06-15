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

	var wing_trails = plane.get_node_or_null("WingTrails")
	if wing_trails != null and wing_trails.has_method("set_trails_visible"):
		wing_trails.set_trails_visible(_resolve_visual_trails_visible())

	var bot_pilot = plane.get_bot_pilot()
	if bot_pilot == null:
		return

	bot_pilot.debug_bot_visuals_enabled = DisplaySettings.bot_debug_enabled

	if DisplaySettings.bot_debug_enabled:
		bot_pilot._ensure_bot_debug_renderer()

	bot_pilot._update_bot_debug_renderer_state()


static func _resolve_visual_trails_visible() -> bool:
	# In a multiplayer session the host's lobby setting is authoritative for all
	# peers; otherwise the local personal display setting applies.
	if Lobby.is_multiplayer_session:
		return Lobby.trails_enabled
	return DisplaySettings.visual_trails_enabled


static func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true

	return false
