extends Node

signal lobby_state_changed(players: Dictionary)
signal session_options_changed(is_game_in_progress: bool, allow_join_in_progress: bool)
signal status_changed(message: String)

const DEFAULT_ADDRESS := "127.0.0.1"
const DEFAULT_PORT := 8910
const MAX_CLIENTS := 16
const LOBBY_SCENE := "res://scenes/lobby.tscn"
const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const WORLD_SCENE := "res://scenes/world_0.tscn"

var last_error := ""
var is_multiplayer_session := false
var is_game_in_progress := false
var allow_join_in_progress := false
var players: Dictionary = {}
var _received_join_rejection := false
var _rejected_peers: Dictionary = {}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func start_single_player() -> void:
	disconnect_session()
	last_error = ""
	get_tree().change_scene_to_file(WORLD_SCENE)


func host(port: int = DEFAULT_PORT) -> Error:
	disconnect_session()

	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(port, MAX_CLIENTS)
	if error != OK:
		last_error = "Could not host on UDP port %d: %s" % [port, error_string(error)]
		return error

	multiplayer.multiplayer_peer = peer
	is_multiplayer_session = true
	is_game_in_progress = false
	allow_join_in_progress = false
	last_error = ""
	players.clear()
	_set_player(1, "Host", false)
	_emit_lobby_state()
	_emit_session_options()
	get_tree().change_scene_to_file(LOBBY_SCENE)
	return OK


func join(address: String = DEFAULT_ADDRESS, port: int = DEFAULT_PORT) -> Error:
	disconnect_session()

	var clean_address := address.strip_edges()
	if clean_address.is_empty():
		clean_address = DEFAULT_ADDRESS

	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(clean_address, port)
	if error != OK:
		last_error = "Could not connect to %s:%d: %s" % [clean_address, port, error_string(error)]
		return error

	multiplayer.multiplayer_peer = peer
	is_multiplayer_session = true
	last_error = "Connecting to %s:%d..." % [clean_address, port]
	_emit_status()
	return OK


func disconnect_session() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null

	is_multiplayer_session = false
	is_game_in_progress = false
	allow_join_in_progress = false
	players.clear()
	_emit_lobby_state()
	_emit_session_options()


func get_local_peer_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return 1

	return multiplayer.get_unique_id()


func is_server_peer() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


func set_local_ready(is_ready: bool) -> void:
	if not is_multiplayer_session:
		return

	if is_server_peer():
		_set_player_ready(get_local_peer_id(), is_ready)
		_broadcast_lobby_state()
	else:
		set_ready.rpc_id(1, is_ready)


func set_allow_join_in_progress(value: bool) -> void:
	if not is_server_peer():
		return

	allow_join_in_progress = value
	_broadcast_session_options()


func start_game() -> Error:
	if not is_server_peer():
		last_error = "Only the host can start the game."
		_emit_status()
		return ERR_UNAUTHORIZED

	is_game_in_progress = true
	_broadcast_session_options()
	_load_world_scene()
	get_tree().process_frame.connect(_broadcast_begin_game, CONNECT_ONE_SHOT)
	return OK


func _on_connected_to_server() -> void:
	last_error = ""
	_emit_status()
	get_tree().change_scene_to_file(LOBBY_SCENE)
	request_lobby_sync.rpc_id(1)


func _on_connection_failed() -> void:
	last_error = "Connection failed."
	disconnect_session()
	_emit_status()


func _on_server_disconnected() -> void:
	if _received_join_rejection:
		_received_join_rejection = false
		var rejection_reason := last_error
		disconnect_session()
		last_error = rejection_reason
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		get_tree().change_scene_to_file(MAIN_MENU_SCENE)
		_emit_status()
		return

	last_error = "Disconnected from server."
	disconnect_session()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	_emit_status()


func _on_peer_connected(peer_id: int) -> void:
	if not is_server_peer():
		return

	if is_game_in_progress and not allow_join_in_progress:
		_reject_peer(peer_id, "Game already in progress.")
		return

	_set_player(peer_id, "Player %d" % peer_id, false)
	_broadcast_lobby_state()


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_server_peer():
		return

	players.erase(peer_id)
	_rejected_peers.erase(peer_id)
	_broadcast_lobby_state()


func _set_player(peer_id: int, player_name: String, is_ready: bool) -> void:
	players[peer_id] = {
		"name": player_name,
		"ready": is_ready,
	}


func _set_player_ready(peer_id: int, is_ready: bool) -> void:
	if not players.has(peer_id):
		_set_player(peer_id, "Player %d" % peer_id, is_ready)
		return

	var player: Dictionary = players[peer_id]
	player["ready"] = is_ready
	players[peer_id] = player


func _broadcast_lobby_state() -> void:
	_emit_lobby_state()
	sync_lobby_state.rpc(players)


func _broadcast_session_options() -> void:
	_emit_session_options()
	sync_session_options.rpc(is_game_in_progress, allow_join_in_progress)


func _emit_lobby_state() -> void:
	lobby_state_changed.emit(players)


func _emit_session_options() -> void:
	session_options_changed.emit(is_game_in_progress, allow_join_in_progress)


func _emit_status() -> void:
	status_changed.emit(last_error)


func _load_world_scene() -> void:
	get_tree().change_scene_to_file(WORLD_SCENE)


func _broadcast_begin_game() -> void:
	if not is_server_peer():
		return

	begin_game.rpc()


func _disconnect_peer(peer_id: int) -> void:
	_rejected_peers.erase(peer_id)
	if multiplayer.multiplayer_peer != null and multiplayer.get_peers().has(peer_id):
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)


func _reject_peer(peer_id: int, reason: String) -> void:
	if _rejected_peers.has(peer_id):
		return

	_rejected_peers[peer_id] = true
	reject_join.rpc_id(peer_id, reason)
	get_tree().create_timer(0.5).timeout.connect(_disconnect_peer.bind(peer_id))


@rpc("any_peer", "reliable")
func request_lobby_sync() -> void:
	if not is_server_peer():
		return

	var sender_id := multiplayer.get_remote_sender_id()

	if is_game_in_progress and not allow_join_in_progress:
		_reject_peer(sender_id, "Game already in progress.")
		return

	if not players.has(sender_id):
		_set_player(sender_id, "Player %d" % sender_id, false)

	sync_session_options.rpc_id(sender_id, is_game_in_progress, allow_join_in_progress)
	sync_lobby_state.rpc_id(sender_id, players)
	_broadcast_lobby_state()

	if is_game_in_progress:
		begin_game.rpc_id(sender_id)


@rpc("any_peer", "reliable")
func set_ready(is_ready: bool) -> void:
	if not is_server_peer():
		return

	_set_player_ready(multiplayer.get_remote_sender_id(), is_ready)
	_broadcast_lobby_state()


@rpc("authority", "reliable")
func sync_lobby_state(server_players: Dictionary) -> void:
	players = server_players
	_emit_lobby_state()


@rpc("authority", "reliable")
func sync_session_options(server_is_game_in_progress: bool, server_allow_join_in_progress: bool) -> void:
	is_game_in_progress = server_is_game_in_progress
	allow_join_in_progress = server_allow_join_in_progress
	_emit_session_options()


@rpc("authority", "reliable")
func begin_game() -> void:
	_load_world_scene()


@rpc("authority", "reliable")
func reject_join(reason: String) -> void:
	_received_join_rejection = true
	last_error = reason
	disconnect_session()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	_emit_status()
