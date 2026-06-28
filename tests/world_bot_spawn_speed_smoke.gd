extends Node3D

const WORLD_SCENE := preload("res://scenes/world_0.tscn")


func _ready() -> void:
	var world_root := WORLD_SCENE.instantiate()
	add_child(world_root)

	await get_tree().create_timer(0.5).timeout

	var spawner := world_root
	_assert(spawner != null, "expected world spawner")

	var characters := spawner.get_node_or_null("characters")
	_assert(characters != null, "expected characters container")

	var bot_speeds: Array[float] = []
	for child in characters.get_children():
		if child is RigidBody3D and bool(child.get("is_bot_controlled")):
			bot_speeds.append((child as RigidBody3D).linear_velocity.length())

	_assert(not bot_speeds.is_empty(), "expected spawned bots")
	for speed in bot_speeds:
		_assert(speed > 1.0, "expected bot spawn speed > 1 m/s, got %.3f" % speed)

	print("world_bot_spawn_speed_smoke_ok bot_speeds=%s" % str(bot_speeds))
	get_tree().quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	get_tree().quit(1)
