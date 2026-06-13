class_name HealthNetReplicator
extends Node

var _spawner


func configure(spawner) -> void:
	_spawner = spawner


func bind_character(character: Node3D, peer_id: int) -> void:
	var health = character.get_health_component()
	if health == null:
		return

	var damaged_callback := Callable(self, "_on_character_damaged").bind(peer_id)
	if not health.damaged.is_connected(damaged_callback):
		health.damaged.connect(damaged_callback)

	var shot_down_callback := Callable(self, "_on_character_shot_down").bind(peer_id)
	if not health.shot_down.is_connected(shot_down_callback):
		health.shot_down.connect(shot_down_callback)


func sync_health_states_to_peer(target_peer_id: int) -> void:
	for peer_id in _spawner._sorted_peer_ids():
		var health = _get_character_health(peer_id)
		if health == null:
			continue

		_spawner.record_net_send("health", [peer_id, health.current_hp])
		cl_health_changed.rpc_id(target_peer_id, peer_id, health.current_hp)
		if _is_character_shot_down(peer_id):
			_spawner.record_net_send("health", [peer_id, true])
			cl_shot_down.rpc_id(target_peer_id, peer_id)


func _get_character_health(peer_id: int):
	var character: Node3D = _spawner.get_character(peer_id)
	if character == null:
		return null

	return character.get_health_component()


func _is_character_shot_down(peer_id: int) -> bool:
	var character: Node3D = _spawner.get_character(peer_id)
	if character == null:
		return false

	return character.is_shot_down


func _on_character_damaged(_amount: float, current_hp: float, peer_id: int) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	for target_peer_id in multiplayer.get_peers():
		if _spawner.is_peer_world_ready(target_peer_id):
			_spawner.record_net_send("health", [peer_id, current_hp])
			cl_health_changed.rpc_id(target_peer_id, peer_id, current_hp)


func _on_character_shot_down(peer_id: int) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return

	for target_peer_id in multiplayer.get_peers():
		if _spawner.is_peer_world_ready(target_peer_id):
			_spawner.record_net_send("health", [peer_id, 0.0])
			cl_health_changed.rpc_id(target_peer_id, peer_id, 0.0)
			_spawner.record_net_send("health", [peer_id, true])
			cl_shot_down.rpc_id(target_peer_id, peer_id)


@rpc("authority", "reliable")
func cl_health_changed(peer_id: int, current_hp: float) -> void:
	_spawner.record_net_recv("health", [peer_id, current_hp])
	var health = _get_character_health(peer_id)
	if health == null:
		return

	health.apply_current_hp_from_network(current_hp)


@rpc("authority", "reliable")
func cl_shot_down(peer_id: int) -> void:
	_spawner.record_net_recv("health", [peer_id, true])
	var health = _get_character_health(peer_id)
	if health != null:
		health.apply_shot_down_from_network()

	var character: Node3D = _spawner.get_character(peer_id)
	if character != null:
		character.apply_remote_shot_down()
