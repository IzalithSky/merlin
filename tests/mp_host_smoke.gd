extends SceneTree

const PORT := 8942
const TOTAL_TIMEOUT_SEC := 12.0
const DAMAGE_DELAY_SEC := 1.0
const POST_DAMAGE_SETTLE_SEC := 2.0

var _elapsed := 0.0
var _booted := false
var _started_game := false
var _damage_applied := false
var _damage_time := 0.0
var _failed := false
var _last_debug_second := -1
var _saw_remote_plane := false
var _validated_local_authority := false


func _process(delta: float) -> bool:
	if _failed:
		return false

	if not _booted:
		_booted = true
		var lobby := get_root().get_node("Lobby")
		var error: Error = lobby.host(PORT)
		_assert(error == OK, "host failed: %s" % lobby.last_error)
		lobby.set_allow_join_in_progress(true)
		return false

	_elapsed += delta
	_debug_status()
	if _elapsed > TOTAL_TIMEOUT_SEC:
		_fail("timeout waiting for multiplayer smoke host completion")
		return false

	var lobby := get_root().get_node("Lobby")
	if not _started_game and lobby.players.size() >= 2:
		var start_error: Error = lobby.start_game()
		_assert(start_error == OK, "start_game failed: %s" % lobby.last_error)
		_started_game = true

	var world := current_scene
	if world == null or world.name != "world":
		return false

	var characters := world.get_node_or_null("characters")
	if characters == null:
		return false

	if _damage_applied and _saw_remote_plane and _validated_local_authority and _elapsed - _damage_time >= POST_DAMAGE_SETTLE_SEC:
		print("mp_host_smoke_ok players=%d" % lobby.players.size())
		quit(0)
		return false

	var local_peer_id := int(lobby.get_local_peer_id())
	var remote_peer_id := _find_remote_player_peer_id(lobby.players, local_peer_id)
	if remote_peer_id < 0:
		return false

	var host_plane := characters.get_node_or_null("PlayerCharacter_%d" % local_peer_id) as Node
	var client_plane := characters.get_node_or_null("PlayerCharacter_%d" % remote_peer_id) as Node
	if host_plane == null or client_plane == null:
		return false

	_assert(_count_local_non_bot_planes(characters) == 1, "host should have exactly one local non-bot plane")
	_assert(bool(host_plane.get("is_local_player")), "host plane should be local on host")
	_assert(not bool(client_plane.get("is_local_player")), "client plane should be remote on host")
	_saw_remote_plane = true
	_validated_local_authority = true

	if not _damage_applied and _elapsed >= DAMAGE_DELAY_SEC:
		var client_health := client_plane.get_node_or_null("Health")
		_assert(client_health != null, "client health missing on host")
		client_health.take_damage(10.0)
		_damage_applied = true
		_damage_time = _elapsed
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
	var lobby := get_root().get_node("Lobby")
	var child_names: Array[String] = []
	if current_scene != null:
		var characters := current_scene.get_node_or_null("characters")
		if characters != null:
			for child in characters.get_children():
				child_names.append(child.name)
	print("host_debug t=%.1f scene=%s players=%d started=%s damaged=%s chars=%s" % [
		_elapsed,
		scene_name,
		lobby.players.size(),
		str(_started_game),
		str(_damage_applied),
		",".join(child_names)
	])


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
	quit(1)
