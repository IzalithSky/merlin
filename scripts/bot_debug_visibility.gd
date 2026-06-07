class_name BotDebugVisibility
extends RefCounted
## Applies the global DisplaySettings debug toggles (force vectors, bot visuals)
## to spawned characters and their bot pilots. Shared by every scene that hosts
## bot characters so the apply logic lives in one place.


static func is_available(node: Node) -> bool:
	return Engine.has_singleton("DisplaySettings") or node.get_node_or_null("/root/DisplaySettings") != null


static func apply_to_characters(characters: Node) -> void:
	if not is_available(characters):
		return

	for character in characters.get_children():
		apply_to_character(character)


static func apply_to_character(character: Node) -> void:
	if _has_property(character, "debug_force_vectors_enabled"):
		character.set("debug_force_vectors_enabled", DisplaySettings.debug_force_arrows_enabled)

	if DisplaySettings.debug_force_arrows_enabled and character.has_method("_ensure_force_debug_renderer"):
		character.call("_ensure_force_debug_renderer")

	if character.has_method("_update_force_debug_renderer_state"):
		character.call("_update_force_debug_renderer_state")

	var bot_pilot := character.get_node_or_null("PlaneBotPilot")
	if bot_pilot == null:
		return

	if _has_property(bot_pilot, "debug_bot_visuals_enabled"):
		bot_pilot.set("debug_bot_visuals_enabled", DisplaySettings.bot_debug_enabled)

	if DisplaySettings.bot_debug_enabled and bot_pilot.has_method("_ensure_bot_debug_renderer"):
		bot_pilot.call("_ensure_bot_debug_renderer")

	if bot_pilot.has_method("_update_bot_debug_renderer_state"):
		bot_pilot.call("_update_bot_debug_renderer_state")


static func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true

	return false
