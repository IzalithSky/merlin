class_name PlaneBotSetup
extends RefCounted


static func configure_plane(
	plane: Node,
	bot_peer: bool,
	bot_active: bool,
	follow_target: Node3D,
	killzone_distance: float,
	killzone_tolerance: float
) -> void:
	plane.team_id = 1 if bot_peer else 2
	plane.set_bot_controlled(bot_active)

	if not bot_active:
		plane.clear_bot_pilot()
		return

	var pilot = plane.ensure_bot_pilot()
	pilot.killzone_distance = killzone_distance
	pilot.killzone_tolerance = killzone_tolerance
	if follow_target != null and follow_target.is_in_group("player_character"):
		pilot.set_follow_target(follow_target)
