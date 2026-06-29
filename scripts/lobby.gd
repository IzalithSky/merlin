extends Node

signal lobby_state_changed(players: Dictionary)
signal session_options_changed(
	is_game_in_progress: bool,
	allow_join_in_progress: bool,
	bot_count: int,
	trails_enabled: bool,
	mission_mode: String,
	multiplayer_player_limit: int
)
signal status_changed(message: String)

const DEFAULT_ADDRESS := "127.0.0.1"
const DEFAULT_PORT := 8910
const MAX_CLIENTS := 16
const DEFAULT_MULTIPLAYER_PLAYER_LIMIT := 8
const LOBBY_SCENE := "res://scenes/lobby.tscn"
const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const WORLD_SCENE := "res://scenes/world_0.tscn"
const MATCH_SYSTEMS_SCENE := preload("res://scenes/match_systems.tscn")
const MISSION_CONTROLLER_SCRIPT := preload("res://scripts/mission_controller.gd")
const DEFAULT_MISSION_CONFIG_PATH := "res://data/missions/default.json"
const FFA_MISSION_CONFIG_PATH := "res://data/missions/ffa.json"
const COOP_MISSION_CONFIG_PATH := "res://data/missions/coop.json"
const MISSION_MODE_FFA := "ffa"
const MISSION_MODE_COOP := "coop"
const MISSION_MODE_LABELS := {
	MISSION_MODE_FFA: "Free For All",
	MISSION_MODE_COOP: "Co-op Mission",
}
const SINGLE_PLAYER_MISSION_DEFS: Array[Dictionary] = [
	{"id": "default", "label": "Combined Arms", "path": "res://data/missions/default.json"},
	{"id": "interceptor", "label": "Interceptor", "path": "res://data/missions/interceptor.json"},
	{"id": "random_skirmish", "label": "Random Skirmish", "path": "res://data/missions/random_skirmish.json"},
]
const COOP_MISSION_DEFS: Array[Dictionary] = [
	{"id": "coop", "label": "Assault", "path": "res://data/missions/coop.json"},
	{"id": "siege", "label": "Siege", "path": "res://data/missions/siege.json"},
]

var last_error := ""
var is_multiplayer_session := false
var is_game_in_progress := false
var allow_join_in_progress := false
var bot_count := 3
var trails_enabled := true
var mission_mode := MISSION_MODE_FFA
var single_player_mission_id := "default"
var coop_mission_id := "coop"
var mission_player_limit := -1
var multiplayer_player_limit := DEFAULT_MULTIPLAYER_PLAYER_LIMIT
var players: Dictionary = {}
var _received_join_rejection := false
var _rejected_peers: Dictionary = {}
var _world_level_randomization: Dictionary = {}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func start_single_player(mission_id := "") -> void:
	disconnect_session()
	if not mission_id.is_empty() and _is_known_single_player_mission(mission_id):
		single_player_mission_id = mission_id
	last_error = ""
	_resolve_current_mission_world_level_randomization()
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
	bot_count = 1
	trails_enabled = true
	mission_mode = MISSION_MODE_FFA
	coop_mission_id = "coop"
	mission_player_limit = _mission_player_limit_for_mode(mission_mode)
	multiplayer_player_limit = DEFAULT_MULTIPLAYER_PLAYER_LIMIT
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
	bot_count = 3
	trails_enabled = true
	mission_mode = MISSION_MODE_FFA
	coop_mission_id = "coop"
	mission_player_limit = -1
	multiplayer_player_limit = DEFAULT_MULTIPLAYER_PLAYER_LIMIT
	players.clear()
	_world_level_randomization.clear()
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


func set_bot_count(value: int) -> void:
	if not is_server_peer():
		return

	bot_count = maxi(value, 0)
	_broadcast_session_options()


func set_mission_mode(value: String) -> void:
	if not is_server_peer():
		return
	if not MISSION_MODE_LABELS.has(value):
		return
	var resolved_mission_player_limit := _mission_player_limit_for_mode(value)
	if resolved_mission_player_limit >= 0 and players.size() > resolved_mission_player_limit:
		last_error = "Selected mission supports up to %d players." % resolved_mission_player_limit
		_emit_status()
		return
	mission_mode = value
	mission_player_limit = resolved_mission_player_limit
	if mission_player_limit >= 0:
		multiplayer_player_limit = mini(multiplayer_player_limit, mission_player_limit)
	last_error = ""
	_broadcast_session_options()
	_emit_status()


func set_coop_mission(value: String) -> void:
	if not is_server_peer():
		return
	if not _is_known_coop_mission(value):
		return
	var resolved_mission_player_limit := _mission_player_limit_for_path(_coop_mission_path(value))
	if mission_mode == MISSION_MODE_COOP and resolved_mission_player_limit >= 0 and players.size() > resolved_mission_player_limit:
		last_error = "Selected mission supports up to %d players." % resolved_mission_player_limit
		_emit_status()
		return
	coop_mission_id = value
	if mission_mode == MISSION_MODE_COOP:
		mission_player_limit = resolved_mission_player_limit
		if mission_player_limit >= 0:
			multiplayer_player_limit = mini(multiplayer_player_limit, mission_player_limit)
	last_error = ""
	_broadcast_session_options()
	_emit_status()


func set_multiplayer_player_limit(value: int) -> void:
	if not is_server_peer():
		return
	var max_limit := MAX_CLIENTS
	if mission_player_limit >= 0:
		max_limit = mini(max_limit, mission_player_limit)
	var resolved_limit := clampi(value, 1, max_limit)
	if resolved_limit < players.size():
		last_error = "Lobby player limit cannot be below current player count."
		_emit_status()
		return
	multiplayer_player_limit = resolved_limit
	last_error = ""
	_broadcast_session_options()
	_emit_status()


func set_trails_enabled(value: bool) -> void:
	if not is_server_peer():
		return

	trails_enabled = value
	_broadcast_session_options()


func start_game() -> Error:
	if not is_server_peer():
		last_error = "Only the host can start the game."
		_emit_status()
		return ERR_UNAUTHORIZED
	if players.size() > get_effective_player_limit():
		last_error = "Lobby has %d players but selected limits allow %d." % [players.size(), get_effective_player_limit()]
		_emit_status()
		return ERR_INVALID_PARAMETER

	is_game_in_progress = true
	_resolve_current_mission_world_level_randomization()
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
	if _is_lobby_full():
		_reject_peer(peer_id, "Lobby is full.")
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
	sync_session_options.rpc(
		is_game_in_progress,
		allow_join_in_progress,
		bot_count,
		trails_enabled,
		mission_mode,
		coop_mission_id,
		multiplayer_player_limit
	)


func _emit_lobby_state() -> void:
	lobby_state_changed.emit(players)


func _emit_session_options() -> void:
	session_options_changed.emit(
		is_game_in_progress,
		allow_join_in_progress,
		bot_count,
		trails_enabled,
		mission_mode,
		multiplayer_player_limit
	)


func _emit_status() -> void:
	status_changed.emit(last_error)


func _load_world_scene() -> void:
	get_tree().change_scene_to_file(WORLD_SCENE)


func compose_world_scene(world_root: Node) -> void:
	if world_root == null or not is_instance_valid(world_root):
		return
	if world_root.find_child("WorldCharacterSpawner", true, false) != null:
		return

	var match_systems := MATCH_SYSTEMS_SCENE.instantiate()
	var controller := match_systems.get_node_or_null("MissionController")
	if controller != null and controller.has_method("set_mission_config_path"):
		controller.call("set_mission_config_path", _resolve_mission_config_path())
	world_root.add_child(match_systems, true)


func _resolve_mission_config_path() -> String:
	if multiplayer.multiplayer_peer == null:
		return _single_player_mission_path(single_player_mission_id)
	if mission_mode == MISSION_MODE_COOP:
		return _coop_mission_path(coop_mission_id)
	return FFA_MISSION_CONFIG_PATH


func _single_player_mission_path(id: String) -> String:
	return _mission_def_path(SINGLE_PLAYER_MISSION_DEFS, id, DEFAULT_MISSION_CONFIG_PATH)


func _coop_mission_path(id: String) -> String:
	return _mission_def_path(COOP_MISSION_DEFS, id, COOP_MISSION_CONFIG_PATH)


func _mission_def_path(defs: Array, id: String, fallback: String) -> String:
	for mission_def: Dictionary in defs:
		if String(mission_def.get("id", "")) == id:
			return String(mission_def.get("path", fallback))
	return fallback


func _is_known_single_player_mission(id: String) -> bool:
	return not _mission_def_path(SINGLE_PLAYER_MISSION_DEFS, id, "").is_empty()


func _is_known_coop_mission(id: String) -> bool:
	return not _mission_def_path(COOP_MISSION_DEFS, id, "").is_empty()


func list_mission_modes() -> Array[Dictionary]:
	return [
		{"id": MISSION_MODE_FFA, "label": MISSION_MODE_LABELS[MISSION_MODE_FFA]},
		{"id": MISSION_MODE_COOP, "label": MISSION_MODE_LABELS[MISSION_MODE_COOP]},
	]


func list_single_player_missions() -> Array[Dictionary]:
	return SINGLE_PLAYER_MISSION_DEFS.duplicate(true)


func list_coop_missions() -> Array[Dictionary]:
	return COOP_MISSION_DEFS.duplicate(true)


func get_mission_mode_max_players() -> int:
	if mission_player_limit < 0:
		return MAX_CLIENTS
	return clampi(mission_player_limit, 1, MAX_CLIENTS)


func get_effective_player_limit() -> int:
	if mission_player_limit < 0:
		return clampi(multiplayer_player_limit, 1, MAX_CLIENTS)
	return mini(clampi(multiplayer_player_limit, 1, MAX_CLIENTS), clampi(mission_player_limit, 1, MAX_CLIENTS))


func _mission_player_limit_for_mode(mode: String) -> int:
	if mode == MISSION_MODE_COOP:
		return _mission_player_limit_for_path(_coop_mission_path(coop_mission_id))
	if mode == MISSION_MODE_FFA:
		return _mission_player_limit_for_path(FFA_MISSION_CONFIG_PATH)
	return -1


func _mission_player_limit_for_path(path: String) -> int:
	var config := MISSION_CONTROLLER_SCRIPT.read_mission_config_file(path)
	if config.is_empty():
		return -1
	return int(config.get("player_limit", -1))


func _is_lobby_full() -> bool:
	return players.size() >= get_effective_player_limit()


func _broadcast_begin_game() -> void:
	if not is_server_peer():
		return

	begin_game.rpc(get_world_level_randomization())


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
	if not players.has(sender_id) and _is_lobby_full():
		_reject_peer(sender_id, "Lobby is full.")
		return

	if is_game_in_progress and not allow_join_in_progress:
		_reject_peer(sender_id, "Game already in progress.")
		return

	if not players.has(sender_id):
		_set_player(sender_id, "Player %d" % sender_id, false)

	sync_session_options.rpc_id(
		sender_id,
		is_game_in_progress,
		allow_join_in_progress,
		bot_count,
		trails_enabled,
		mission_mode,
		coop_mission_id,
		multiplayer_player_limit
	)
	sync_lobby_state.rpc_id(sender_id, players)
	_broadcast_lobby_state()

	if is_game_in_progress:
		begin_game.rpc_id(sender_id, get_world_level_randomization())


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
func sync_session_options(
	server_is_game_in_progress: bool,
	server_allow_join_in_progress: bool,
	server_bot_count: int,
	server_trails_enabled: bool,
	server_mission_mode: String,
	server_coop_mission_id: String,
	server_multiplayer_player_limit: int
) -> void:
	is_game_in_progress = server_is_game_in_progress
	allow_join_in_progress = server_allow_join_in_progress
	bot_count = maxi(server_bot_count, 0)
	trails_enabled = server_trails_enabled
	mission_mode = String(server_mission_mode)
	coop_mission_id = String(server_coop_mission_id)
	mission_player_limit = _mission_player_limit_for_mode(mission_mode)
	multiplayer_player_limit = clampi(server_multiplayer_player_limit, 1, MAX_CLIENTS)
	_emit_session_options()


@rpc("authority", "reliable")
func begin_game(world_level_randomization: Dictionary = {}) -> void:
	if not world_level_randomization.is_empty():
		_world_level_randomization = world_level_randomization.duplicate(true)
	elif _world_level_randomization.is_empty():
		_resolve_current_mission_world_level_randomization()
	_load_world_scene()


@rpc("authority", "reliable")
func reject_join(reason: String) -> void:
	_received_join_rejection = true
	last_error = reason
	disconnect_session()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	_emit_status()


func get_world_level_randomization() -> Dictionary:
	return _world_level_randomization.duplicate(true)


func set_world_level_randomization(randomization: Dictionary) -> void:
	_world_level_randomization = randomization.duplicate(true)


func _resolve_current_mission_world_level_randomization() -> void:
	var config := MISSION_CONTROLLER_SCRIPT.read_mission_config_file(_resolve_mission_config_path())
	_world_level_randomization = MISSION_CONTROLLER_SCRIPT.resolve_world_level_randomization(config)
