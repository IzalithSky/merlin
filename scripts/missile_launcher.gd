class_name MissileLauncher
extends Node

const MISSILE_SCENE := preload("res://scenes/missile.tscn")

@export var fire_cooldown: float = 2.5
@export var launch_lateral_offset: float = 5.0
@export var launch_vertical_offset: float = 0.0
@export var launch_forward_offset: float = 0.0

var _cooldown_remaining: float = 0.0
var _projectiles_container: Node = null
var _next_hardpoint_index: int = 0


func _ready() -> void:
	var projectile_net = _find_projectile_net()
	if projectile_net != null:
		_projectiles_container = projectile_net.get_projectiles_container()
		if _projectiles_container != null:
			return

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
	var locked_target_component = null
	var weapon_lock = plane.get_weapon_lock_component()
	if weapon_lock != null and is_instance_valid(weapon_lock):
		locked_target = weapon_lock.get_locked_target()
		locked_target_component = weapon_lock.get_locked_target_component()

	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		var target_kind := -1
		var target_id := -1
		if locked_target_component != null and is_instance_valid(locked_target_component):
			target_kind = locked_target_component.get_target_kind()
			target_id = locked_target_component.get_target_id()
		var projectile_net := _find_projectile_net()
		if projectile_net != null:
			var spawner = WorldCharacterSpawner.find_in_tree(self)
			if spawner != null:
				spawner.record_net_send("projectile", [multiplayer.get_unique_id(), target_kind, target_id])
			projectile_net.sv_request_fire_missile.rpc_id(1, multiplayer.get_unique_id(), target_kind, target_id)
	else:
		var projectile_net := _find_projectile_net()
		if projectile_net != null:
			projectile_net.fire_missile(plane, locked_target)
		else:
			_fire(plane, locked_target)

	_cooldown_remaining = fire_cooldown


func _fire(plane: Node3D, locked_target: Node3D) -> void:
	var missile = MISSILE_SCENE.instantiate()
	missile.global_transform = get_and_advance_launch_transform(plane)
	missile.target = locked_target
	missile.host = plane
	if plane is RigidBody3D:
		missile.linear_velocity = (plane as RigidBody3D).linear_velocity
	_projectiles_container.add_child(missile)

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


func _find_projectile_net() -> Node:
	var world_nodes := get_tree().get_nodes_in_group("world_character_spawner")
	if world_nodes.is_empty():
		return null
	var spawner = world_nodes[0]
	if spawner == null or not is_instance_valid(spawner):
		return null
	return spawner.get_projectile_net()
