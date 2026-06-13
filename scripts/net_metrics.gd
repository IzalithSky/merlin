class_name NetMetrics
extends RefCounted

const WINDOW_SECONDS := 1.0
const KINDS := ["state", "input", "spawn", "health", "projectile"]

var _events: Array[Dictionary] = []


func record_send(kind: String, byte_len: int) -> void:
	_record_event("send", kind, byte_len)


func record_recv(kind: String, byte_len: int) -> void:
	_record_event("recv", kind, byte_len)


func get_summary() -> Dictionary:
	_prune_events()
	return {
		"window_seconds": WINDOW_SECONDS,
		"send": _build_direction_summary("send"),
		"recv": _build_direction_summary("recv"),
	}


func get_summary_text() -> String:
	var summary := get_summary()
	var send_summary: Dictionary = summary["send"]
	var recv_summary: Dictionary = summary["recv"]
	var segments := [
		"S %.0f pkt/s %.1f KB/s" % [
			float(send_summary.get("packets_per_sec", 0.0)),
			float(send_summary.get("bytes_per_sec", 0.0)) / 1024.0,
		],
		"R %.0f pkt/s %.1f KB/s" % [
			float(recv_summary.get("packets_per_sec", 0.0)),
			float(recv_summary.get("bytes_per_sec", 0.0)) / 1024.0,
		],
	]

	for kind in KINDS:
		var send_kind: Dictionary = send_summary.get("by_kind", {}).get(kind, {})
		var recv_kind: Dictionary = recv_summary.get("by_kind", {}).get(kind, {})
		var send_packets := float(send_kind.get("packets_per_sec", 0.0))
		var recv_packets := float(recv_kind.get("packets_per_sec", 0.0))
		var send_bytes := float(send_kind.get("bytes_per_sec", 0.0))
		var recv_bytes := float(recv_kind.get("bytes_per_sec", 0.0))
		if send_packets <= 0.0 and recv_packets <= 0.0:
			continue
		segments.append(
			"%s S%.0f/%.1f R%.0f/%.1f" % [
				kind.left(2).to_upper(),
				send_packets,
				send_bytes / 1024.0,
				recv_packets,
				recv_bytes / 1024.0,
			]
		)

	return " | ".join(segments)


func _record_event(direction: String, kind: String, byte_len: int) -> void:
	_events.append({
		"time": Time.get_ticks_usec() / 1000000.0,
		"direction": direction,
		"kind": kind,
		"bytes": maxi(byte_len, 0),
	})
	_prune_events()


func _prune_events() -> void:
	var cutoff := Time.get_ticks_usec() / 1000000.0 - WINDOW_SECONDS
	while not _events.is_empty() and float(_events[0].get("time", 0.0)) < cutoff:
		_events.pop_front()


func _build_direction_summary(direction: String) -> Dictionary:
	var packet_count := 0
	var byte_count := 0
	var by_kind := {}
	for kind in KINDS:
		by_kind[kind] = {
			"packets": 0,
			"bytes": 0,
			"packets_per_sec": 0.0,
			"bytes_per_sec": 0.0,
		}

	for event in _events:
		if String(event.get("direction", "")) != direction:
			continue
		packet_count += 1
		var event_bytes := int(event.get("bytes", 0))
		byte_count += event_bytes
		var kind := String(event.get("kind", ""))
		if not by_kind.has(kind):
			by_kind[kind] = {
				"packets": 0,
				"bytes": 0,
				"packets_per_sec": 0.0,
				"bytes_per_sec": 0.0,
			}
		var entry: Dictionary = by_kind[kind]
		entry["packets"] = int(entry.get("packets", 0)) + 1
		entry["bytes"] = int(entry.get("bytes", 0)) + event_bytes
		by_kind[kind] = entry

	for kind in by_kind.keys():
		var entry: Dictionary = by_kind[kind]
		entry["packets_per_sec"] = float(entry.get("packets", 0)) / WINDOW_SECONDS
		entry["bytes_per_sec"] = float(entry.get("bytes", 0)) / WINDOW_SECONDS
		by_kind[kind] = entry

	return {
		"packets": packet_count,
		"bytes": byte_count,
		"packets_per_sec": float(packet_count) / WINDOW_SECONDS,
		"bytes_per_sec": float(byte_count) / WINDOW_SECONDS,
		"by_kind": by_kind,
	}
