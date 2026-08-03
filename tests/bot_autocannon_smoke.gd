extends Node3D

const PLANE_SCENE := preload("res://scenes/plane_character.tscn")
const BOT_PILOT_SCRIPT := preload("res://scripts/plane_bot_pilot.gd")


func _ready() -> void:
	var bot_plane := PLANE_SCENE.instantiate() as PlaneCharacter
	bot_plane.name = "BotPlane"
	add_child(bot_plane)
	bot_plane.configure(1000000, false)
	bot_plane.set_bot_controlled(true)
	bot_plane.global_position = Vector3.ZERO
	bot_plane.linear_velocity = Vector3.ZERO

	var target_plane := PLANE_SCENE.instantiate() as PlaneCharacter
	target_plane.name = "TargetPlane"
	add_child(target_plane)
	target_plane.configure(2, false)
	target_plane.set_bot_controlled(false)
	target_plane.global_position = Vector3(0.0, 0.0, -400.0)
	target_plane.linear_velocity = Vector3.ZERO

	var pilot := BOT_PILOT_SCRIPT.new()
	pilot.name = "PlaneBotPilot"
	pilot.set("autocannon_fire_max_range", 500.0)
	bot_plane.add_child(pilot)
	pilot.call("set_follow_target", target_plane)

	await get_tree().create_timer(0.2).timeout

	var bullets := get_tree().get_nodes_in_group("bullet")
	_assert(bullets.size() >= 1, "expected bot to fire autocannon")

	print("bot_autocannon_smoke_ok bullet_count=%d" % bullets.size())
	get_tree().quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	get_tree().quit(1)
