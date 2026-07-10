class_name PlaneBotSetup
extends RefCounted


static func configure_plane(
	plane: Node,
	bot_peer: bool,
	bot_active: bool,
	killzone_distance: float,
	killzone_tolerance: float,
	autocannon_fire_max_range: float = -1.0,
	debug_bot_visuals_enabled: bool = true,
	team_id_override: int = -1
) -> Node:
	plane.team_id = team_id_override if team_id_override >= 0 else (1 if bot_peer else 2)
	plane.set_bot_controlled(bot_active)

	if not bot_active:
		plane.clear_bot_pilot()
		return null

	var pilot = plane.ensure_bot_pilot()
	pilot.killzone_distance = killzone_distance
	pilot.killzone_tolerance = killzone_tolerance
	pilot.debug_bot_visuals_enabled = debug_bot_visuals_enabled
	if autocannon_fire_max_range >= 0.0:
		pilot.autocannon_fire_max_range = autocannon_fire_max_range
	return pilot
