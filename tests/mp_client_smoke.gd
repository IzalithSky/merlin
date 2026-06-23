extends SceneTree

const PORT := 8942
const TOTAL_TIMEOUT_SEC := 12.0
# Stay connected after the success condition so the host smoke can keep
# observing this peer's server-simulated plane (movement assertion).
const POST_SUCCESS_LINGER_SEC := 4.0

var _elapsed := 0.0
var _booted := false
var _failed := false
var _last_debug_second := -1
var _hp_synced := false
var _hp_synced_time := 0.0
var _finishing := false


func _process(delta: float) -> bool:
	if _failed:
		return false
	if _finishing:
		return false

	if not _booted:
		_booted = true
		var lobby := get_root().get_node("Lobby")
		var error: Error = lobby.join("127.0.0.1", PORT)
		_assert(error == OK, "join failed: %s" % lobby.last_error)
		return false

	_elapsed += delta
	_debug_status()
	if _elapsed > TOTAL_TIMEOUT_SEC:
		_fail("timeout waiting for multiplayer smoke client completion")
		return false

	if _hp_synced:
		var world_gone := current_scene == null or current_scene.name != "world"
		if world_gone or _elapsed - _hp_synced_time >= POST_SUCCESS_LINGER_SEC:
			print("mp_client_smoke_ok hp=90.0")
			_finish(0)
		return false

	var world := current_scene
	if world == null or world.name != "world":
		return false

	var characters := world.get_node_or_null("characters")
	if characters == null:
		return false

	var lobby := get_root().get_node("Lobby")
	var local_peer_id := int(lobby.get_local_peer_id())
	var remote_peer_id := _find_remote_player_peer_id(lobby.players, local_peer_id)
	if remote_peer_id < 0:
		return false

	var host_plane := characters.get_node_or_null("PlayerCharacter_%d" % remote_peer_id) as Node
	var client_plane := characters.get_node_or_null("PlayerCharacter_%d" % local_peer_id) as Node
	if host_plane == null or client_plane == null:
		return false

	_assert(_count_local_non_bot_planes(characters) == 1, "client should have exactly one local non-bot plane")
	_assert(not bool(host_plane.get("is_local_player")), "host plane should be remote on client")
	_assert(bool(client_plane.get("is_local_player")), "client plane should be local on client")

	var client_health := client_plane.get_node_or_null("Health")
	_assert(client_health != null, "client health missing on client")
	if absf(float(client_health.get("current_hp")) - 90.0) < 0.01:
		_hp_synced = true
		_hp_synced_time = _elapsed
	return false


func _find_remote_player_peer_id(players: Dictionary, local_peer_id: int) -> int:
	for peer_id_variant in players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id != local_peer_id:
			return peer_id
	return -1


func _debug_status() -> void:
	var second := int(floor(_elapsed))
	if second == _last_debug_second:
		return
	_last_debug_second = second
	var scene_name := "<none>"
	if current_scene != null:
		scene_name = current_scene.name
	var child_names: Array[String] = []
	var hp_value := -1.0
	if current_scene != null:
		var characters := current_scene.get_node_or_null("characters")
		if characters != null:
			for child in characters.get_children():
				child_names.append(child.name)
			var lobby := get_root().get_node("Lobby")
			var local_plane := characters.get_node_or_null("PlayerCharacter_%d" % int(lobby.get_local_peer_id()))
			if local_plane != null:
				var health := local_plane.get_node_or_null("Health")
				if health != null:
					hp_value = float(health.get("current_hp"))
	print("client_debug t=%.1f scene=%s chars=%s hp=%.1f" % [_elapsed, scene_name, ",".join(child_names), hp_value])


func _count_local_non_bot_planes(characters: Node) -> int:
	var count := 0
	for child in characters.get_children():
		if bool(child.get("is_bot_controlled")):
			continue
		if bool(child.get("is_local_player")):
			count += 1
	return count


func _assert(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	_finish(1)


func _finish(exit_code: int) -> void:
	if _finishing:
		return
	_finishing = true
	call_deferred("_deferred_finish", exit_code)


func _deferred_finish(exit_code: int) -> void:
	await process_frame
	var scene := current_scene
	if scene != null and is_instance_valid(scene):
		scene.free()
	quit(exit_code)
