class_name PlaneBotDebugAdapter
extends RefCounted

var _pilot: PlaneBotPilot
var _bot_debug_renderer


func _init(pilot: PlaneBotPilot) -> void:
	_pilot = pilot


func handle_shot_down() -> void:
	if _bot_debug_renderer != null:
		_bot_debug_renderer.clear()
		_bot_debug_renderer.visible = false
		_bot_debug_renderer = null


func ensure_renderer() -> void:
	if not _pilot.debug_bot_visuals_enabled:
		return
	if _bot_debug_renderer != null:
		return
	_bot_debug_renderer = _pilot.BOT_DEBUG_RENDERER_SCRIPT.new()
	_bot_debug_renderer.name = "BotDebugRenderer3D"
	_pilot.add_child(_bot_debug_renderer)
	update_renderer_state()


func update_renderer_state() -> void:
	if _bot_debug_renderer == null:
		return
	var should_show: bool = _pilot.debug_bot_visuals_enabled and _pilot._plane != null and _pilot._plane.is_inside_tree()
	_bot_debug_renderer.visible = should_show
	if not should_show:
		_bot_debug_renderer.clear()


func update_visuals() -> void:
	if not _pilot.debug_bot_visuals_enabled:
		update_renderer_state()
		return

	ensure_renderer()
	update_renderer_state()
	if _bot_debug_renderer == null or not _bot_debug_renderer.visible:
		return

	var engagement_snapshot := _pilot.get_engagement_debug_snapshot()
	var has_target: bool = engagement_snapshot["has_target"]
	var intent_position: Vector3 = engagement_snapshot["intent_position"]
	var has_killzone: bool = engagement_snapshot["has_killzone"]
	var killzone_position: Vector3 = engagement_snapshot["killzone_position"]
	var source_target_position: Vector3 = engagement_snapshot["source_target_position"]

	_bot_debug_renderer.update_visuals(
		_pilot._frame_position,
		_pilot._frame_forward_axis,
		_pilot._frame_basis.y,
		has_target,
		intent_position,
		has_killzone,
		killzone_position,
		has_target,
		source_target_position,
		_pilot._idle_checkpoint_active,
		_pilot._idle_checkpoint,
		_get_bot_debug_label_text()
	)


func _get_bot_debug_label_text() -> String:
	var target_text := _pilot.get_follow_target_debug_label()
	var aggro_text := _pilot.get_highest_aggro_debug_label()
	var checkpoint_text := "--"
	if _pilot._idle_checkpoint_active:
		checkpoint_text = "(%.0f, %.0f, %.0f) %.1fs" % [
			_pilot._idle_checkpoint.x,
			_pilot._idle_checkpoint.y,
			_pilot._idle_checkpoint.z,
			maxf(_pilot._idle_checkpoint_time_remaining, 0.0),
		]
	elif _pilot._has_follow_target():
		checkpoint_text = "PAUSED (TARGET)"
	elif not _pilot._has_idle_patrol_area():
		checkpoint_text = "NO AREA"
	else:
		checkpoint_text = "PENDING"
	return "BOT %s\nTGT %s\nAGG %s\nCHK %s\nSPD %.0f m/s  THR %+.2f\nROL %+.2f  PIT %+.2f" % [
		_pilot.get_flight_state_name(),
		target_text,
		aggro_text,
		checkpoint_text,
		_pilot._frame_speed,
		_pilot._throttle_input,
		_pilot._roll_input,
		_pilot._pitch_input,
	]
