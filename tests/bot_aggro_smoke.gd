extends Node3D

const PLANE_SCENE := preload("res://scenes/plane_character.tscn")
const BOT_PILOT_SCRIPT := preload("res://scripts/plane_bot_pilot.gd")


func _ready() -> void:
	var bot_plane := PLANE_SCENE.instantiate() as PlaneCharacter
	bot_plane.name = "BotPlane"
	add_child(bot_plane)
	bot_plane.configure(1000000, false)
	bot_plane.set_bot_controlled(true)
	bot_plane.team_id = 1
	bot_plane.global_position = Vector3(0.0, 1000.0, 0.0)
	bot_plane.linear_velocity = Vector3.ZERO

	var target_plane := PLANE_SCENE.instantiate() as PlaneCharacter
	target_plane.name = "TargetPlane"
	add_child(target_plane)
	target_plane.configure(2, false)
	target_plane.set_bot_controlled(false)
	target_plane.team_id = 2
	target_plane.global_position = Vector3(0.0, 1000.0, -700.0)
	target_plane.linear_velocity = Vector3.ZERO

	var pilot := BOT_PILOT_SCRIPT.new()
	pilot.name = "PlaneBotPilot"
	pilot.set("hostile_aggro_radius", 500.0)
	pilot.set("hostile_aggro_threshold", 0.2)
	pilot.set("hostile_aggro_gain_per_second", 1.0)
	pilot.set("hostile_aggro_decay_per_second", 1.0)
	bot_plane.add_child(pilot)

	await get_tree().create_timer(0.1).timeout
	_assert(not _has_target(pilot), "expected no default target outside aggro radius")

	target_plane.global_position = Vector3(0.0, 1000.0, -400.0)
	await get_tree().create_timer(0.05).timeout
	_assert(not _has_target(pilot), "expected aggro threshold delay before acquiring target")

	await get_tree().create_timer(0.2).timeout
	_assert(_has_target(pilot), "expected hostile target after aggro threshold")

	target_plane.global_position = Vector3(0.0, 1000.0, -700.0)
	await get_tree().create_timer(0.1).timeout
	_assert(_has_target(pilot), "expected target to persist while aggro decays")

	await get_tree().create_timer(0.2).timeout
	_assert(not _has_target(pilot), "expected target to clear after aggro decays")

	print("bot_aggro_smoke_ok")
	get_tree().quit(0)


func _has_target(pilot: Node) -> bool:
	var snapshot: Dictionary = pilot.call("get_engagement_debug_snapshot")
	return bool(snapshot.get("has_target", false))


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	get_tree().quit(1)
