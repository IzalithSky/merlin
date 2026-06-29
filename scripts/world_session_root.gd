extends Node3D

var _net_metrics_enabled := false
var _net_metrics_print_summary := false

var net_metrics_enabled: bool:
	get:
		return _net_metrics_enabled
	set(value):
		_net_metrics_enabled = value
		var spawner := find_child("WorldCharacterSpawner", true, false) as WorldCharacterSpawner
		if spawner != null:
			spawner.net_metrics_enabled = value

var net_metrics_print_summary: bool:
	get:
		return _net_metrics_print_summary
	set(value):
		_net_metrics_print_summary = value
		var spawner := find_child("WorldCharacterSpawner", true, false) as WorldCharacterSpawner
		if spawner != null:
			spawner.net_metrics_print_summary = value

func _ready() -> void:
	call_deferred("_compose_match_systems")


func _compose_match_systems() -> void:
	if find_child("WorldCharacterSpawner", true, false) != null:
		return
	var lobby := get_node_or_null("/root/Lobby")
	if lobby == null or not lobby.has_method("compose_world_scene"):
		return
	lobby.call("compose_world_scene", self)
	var spawner := find_child("WorldCharacterSpawner", true, false) as WorldCharacterSpawner
	if spawner != null:
		spawner.net_metrics_enabled = _net_metrics_enabled
		spawner.net_metrics_print_summary = _net_metrics_print_summary
