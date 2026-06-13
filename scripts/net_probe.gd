class_name NetProbe
extends RefCounted

# Lightweight diagnostic logger for multiplayer jitter investigation.
#
# Writes one log file per running process to:
#   user://net_probe_<pid>.log
# (on Linux: ~/.local/share/godot/app_userdata/merlin/net_probe_<pid>.log)
#
# Two instances on one machine (dual-box) get distinct files via pid. Each line
# carries a role token (s = server/host, c = client, l = local-no-peer) so the
# files are self-identifying.
#
# Toggle ENABLED to false (or set NET_PROBE=0 in the environment) to disable all
# logging with near-zero overhead. Remove the probe call sites when done.

const ENABLED := true

static var _file: FileAccess = null
static var _opened := false
static var _pending_flush := 0
static var _start_usec := 0


static func _is_enabled() -> bool:
	if not ENABLED:
		return false
	if OS.has_environment("NET_PROBE") and OS.get_environment("NET_PROBE") == "0":
		return false
	return true


static func _ensure_open() -> void:
	if _opened:
		return
	_opened = true
	if not _is_enabled():
		return
	var pid := OS.get_process_id()
	var path := "user://net_probe_%d.log" % pid
	_file = FileAccess.open(path, FileAccess.WRITE)
	_start_usec = Time.get_ticks_usec()
	if _file != null:
		_file.store_line("# net_probe pid=%d start_usec=%d" % [pid, _start_usec])
		_file.flush()


static func _role() -> String:
	var loop := Engine.get_main_loop()
	var tree := loop as SceneTree
	if tree == null:
		return "?"
	var mp := tree.get_multiplayer()
	if mp == null or not mp.has_multiplayer_peer():
		return "l"
	return "s" if mp.is_server() else "c"


static func log_line(category: String, fields: String) -> void:
	if not _is_enabled():
		return
	_ensure_open()
	if _file == null:
		return
	# t_ms since process start, physics frame, role, category, then payload.
	var t_ms := float(Time.get_ticks_usec() - _start_usec) * 0.001
	_file.store_line("%.3f f=%d %s %s %s" % [
		t_ms,
		Engine.get_physics_frames(),
		_role(),
		category,
		fields,
	])
	_pending_flush += 1
	if _pending_flush >= 30:
		_pending_flush = 0
		_file.flush()


static func flush() -> void:
	if _file != null:
		_file.flush()
