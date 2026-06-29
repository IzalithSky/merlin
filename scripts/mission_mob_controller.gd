class_name MissionMobController
extends Node3D

@export var mission_config_path := ""

var _spawner: WorldCharacterSpawner = null
var _bootstrapped := false


func _ready() -> void:
	add_to_group("mission_mob_controller")
	call_deferred("_bootstrap_default_session")


func set_mission_config_path(path: String) -> void:
	mission_config_path = path


func _bootstrap_default_session() -> void:
	if _bootstrapped:
		return
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		return
	_spawner = _find_spawner()
	if _spawner == null:
		return
	_bootstrapped = true
	_spawner.begin_default_session()


func _find_spawner() -> WorldCharacterSpawner:
	var parent := get_parent()
	if parent != null:
		var sibling := parent.get_node_or_null("WorldCharacterSpawner") as WorldCharacterSpawner
		if sibling != null:
			return sibling
	var nodes := get_tree().get_nodes_in_group("world_character_spawner")
	if nodes.is_empty():
		return null
	return nodes[0] as WorldCharacterSpawner
