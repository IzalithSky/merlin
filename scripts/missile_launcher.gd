class_name MissileLauncher
extends Node

const MISSILE_SCENE := preload("res://scenes/missile.tscn")

@export var fire_cooldown: float = 1.0
@export var launch_lateral_offset: float = 5.0
@export var launch_vertical_offset: float = 0.0
@export var launch_forward_offset: float = 0.0

var _cooldown_remaining: float = 0.0
var _projectiles_container: Node = null
var _next_hardpoint_index: int = 0


func _ready() -> void:
	_projectiles_container = get_tree().current_scene.get_node_or_null("projectiles")
	if _projectiles_container == null:
		push_warning("MissileLauncher: no 'projectiles' node found in scene root; missiles will be added to scene root")
		_projectiles_container = get_tree().current_scene


func _process(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining -= delta

	var plane := get_parent()
	if plane == null or not is_instance_valid(plane):
		return

	if not _is_local_player(plane):
		return

	if plane.is_shot_down:
		return

	if Input.is_action_just_pressed("fire_missile") and _cooldown_remaining <= 0.0:
		_try_fire(plane)


func try_fire() -> void:
	if _cooldown_remaining > 0.0:
		return
	var plane := get_parent()
	if plane == null or not is_instance_valid(plane):
		return
	if plane.is_shot_down:
		return
	_try_fire(plane)


func _try_fire(plane: Node3D) -> void:
	if plane.is_shot_down:
		return

	var locked_target: Node3D = null
	var weapon_lock = plane.get_weapon_lock_component()
	if weapon_lock != null and is_instance_valid(weapon_lock):
		locked_target = weapon_lock.get_locked_target()

	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		var target_peer_id := -1
		if locked_target.is_in_group("plane_character"):
			target_peer_id = locked_target.peer_id
		var spawner := _find_world_spawner()
		if spawner != null:
			spawner.sv_request_fire_missile.rpc_id(1, multiplayer.get_unique_id(), target_peer_id)
	else:
		_fire(plane, locked_target)

	_cooldown_remaining = fire_cooldown


func _fire(plane: Node3D, locked_target: Node3D) -> void:
	var missile = MISSILE_SCENE.instantiate()
	missile.global_transform = get_and_advance_launch_transform(plane)
	missile.target = locked_target
	missile.host = plane

	_projectiles_container.add_child(missile)

	if plane is RigidBody3D:
		missile.linear_velocity = (plane as RigidBody3D).linear_velocity

	missile.add_collision_exception_with(plane)


func get_and_advance_launch_transform(plane: Node3D) -> Transform3D:
	var side_sign := -1.0 if _next_hardpoint_index % 2 == 0 else 1.0
	_next_hardpoint_index += 1

	var basis := plane.global_transform.basis
	var origin := plane.global_position
	origin += basis.x * launch_lateral_offset * side_sign
	origin += basis.y * launch_vertical_offset
	origin += -basis.z * launch_forward_offset

	return Transform3D(plane.global_transform.basis, origin)


func _is_local_player(plane: Node3D) -> bool:
	return plane.is_local_player


func _find_world_spawner() -> Node:
	var world_nodes := get_tree().get_nodes_in_group("world_character_spawner")
	if world_nodes.is_empty():
		return null
	return world_nodes[0]
