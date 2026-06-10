extends Node

const MISSILE_SCENE := preload("res://scenes/missile.tscn")

@export var fire_cooldown: float = 1.0

var _cooldown_remaining: float = 0.0
var _projectiles_container: Node3D = null


func _ready() -> void:
	_projectiles_container = get_tree().current_scene.get_node_or_null("projectiles") as Node3D
	if _projectiles_container == null:
		push_warning("PlaneMissileLauncher: no 'projectiles' node found in scene root; missiles will be added to scene root")
		_projectiles_container = get_tree().current_scene


func _process(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining -= delta

	var plane := get_parent() as Node3D
	if plane == null or not is_instance_valid(plane):
		return

	if not _is_local_player(plane):
		return

	if Input.is_action_just_pressed("fire_missile") and _cooldown_remaining <= 0.0:
		_try_fire(plane)


func _try_fire(plane: Node3D) -> void:
	var locked_target: Node3D = null
	var weapon_lock := plane.get_node_or_null("PlaneWeaponLock")
	if weapon_lock != null and is_instance_valid(weapon_lock):
		locked_target = weapon_lock.call("get_locked_target") as Node3D

	_fire(plane, locked_target)
	_cooldown_remaining = fire_cooldown


func _fire(plane: Node3D, locked_target: Node3D) -> void:
	var missile := MISSILE_SCENE.instantiate() as RigidBody3D
	missile.global_transform = plane.global_transform
	if "target" in missile:
		missile.set("target", locked_target)
	if "host" in missile:
		missile.set("host", plane)

	_projectiles_container.add_child(missile)

	if plane is RigidBody3D:
		missile.linear_velocity = (plane as RigidBody3D).linear_velocity

	if missile.has_method("add_collision_exception_with"):
		missile.add_collision_exception_with(plane)


func _is_local_player(plane: Node3D) -> bool:
	var lp: Variant = plane.get("is_local_player")
	if lp != null:
		return bool(lp)
	return true
