class_name PlaneNetAdapter
extends RefCounted

const REMOTE_INTERPOLATION_DELAY := 0.1
const REMOTE_MAX_SNAPSHOTS := 4
const PREDICTION_HISTORY_MAX := 180
const RECONCILE_VELOCITY_TOLERANCE := 15.0
const RECONCILE_ANGULAR_VELOCITY_TOLERANCE_DEG := 20.0
const RECONCILE_ROTATION_TOLERANCE_DEG := 10.0

var _plane
var _remote_snapshots: Array[Dictionary] = []
var _net_input_seq := 0
var _net_pending_input: Dictionary = {}
var _net_last_applied_input_seq := -1
var _net_ack_seq := -1
var _prediction_history: Array[Dictionary] = []
var _correction_position := Vector3.ZERO
var _latest_server_tick := -1
var _render_tick_continuous := 0.0
var _render_tick_initialized := false
var _awaiting_first_shot_down_snapshot := false


func _init(plane) -> void:
	_plane = plane


func apply_net_control_input(input: Dictionary) -> void:
	var input_seq := int(input.get("seq", -1))
	var newest_known := maxi(int(_net_pending_input.get("seq", -1)), _net_last_applied_input_seq)
	if input_seq <= newest_known:
		return
	_net_pending_input = input


func consume_pending_input() -> Dictionary:
	# Latch the ack before consuming a newer input: the body state this tick was
	# integrated from the previously applied seq.
	_net_ack_seq = _net_last_applied_input_seq
	if _net_pending_input.is_empty():
		return {}

	var input: Dictionary = _net_pending_input
	_net_pending_input = {}
	var input_seq := int(input.get("seq", -1))
	if input_seq <= _net_last_applied_input_seq:
		return {}

	_net_last_applied_input_seq = input_seq
	return input


func build_local_input_payload() -> PackedByteArray:
	if not _plane._is_predicting_client():
		return PackedByteArray()
	return _plane._input_collector.build_local_input_payload(next_input_seq())


func next_input_seq() -> int:
	_net_input_seq += 1
	return _net_input_seq


func record_prediction_state() -> void:
	if not _plane._is_predicting_client():
		return

	# Top of the physics tick: the body state is the integrated result of the
	# forces computed from input seq `_net_input_seq` (sent last tick).
	_prediction_history.append({
		"seq": _net_input_seq,
		"position": _plane.global_position,
		"rotation": _plane.global_transform.basis.orthonormalized().get_rotation_quaternion(),
		"linear_velocity": _plane.linear_velocity,
		"angular_velocity": _plane.angular_velocity,
	})
	while _prediction_history.size() > PREDICTION_HISTORY_MAX:
		_prediction_history.pop_front()


func apply_pending_correction(delta: float) -> void:
	if not _plane._is_predicting_client():
		return
	if _correction_position.length_squared() <= 0.000001:
		return

	var fold_fraction := clampf(_plane.reconcile_correction_rate * delta, 0.0, 1.0)
	var step := _correction_position * fold_fraction
	_plane.global_position += step
	for entry in _prediction_history:
		entry["position"] = Vector3(entry["position"]) + step
	_correction_position -= step


func apply_remote_state(snapshot: Dictionary) -> void:
	if _plane.is_local_player:
		return

	_store_interpolation_snapshot(snapshot)


func apply_authoritative_state(snapshot: Dictionary) -> void:
	if not _plane.is_local_player:
		return

	if not _plane._is_simulated_locally():
		if _awaiting_first_shot_down_snapshot:
			_apply_first_shot_down_snapshot(snapshot)
			return
		_store_interpolation_snapshot(snapshot)
		return

	_reconcile_with_server_state(snapshot)


func update_remote_interpolation(delta: float) -> void:
	if _remote_snapshots.is_empty():
		return

	var tick_hz := maxf(_plane.get_server_net_tick_hz(), 0.001)
	var interpolation_delay_ticks := maxf(ceil(REMOTE_INTERPOLATION_DELAY * tick_hz), 1.0)
	var target_render_tick := float(_latest_server_tick) - interpolation_delay_ticks
	if not _render_tick_initialized:
		_render_tick_continuous = target_render_tick
		_render_tick_initialized = true
	else:
		_render_tick_continuous = minf(_render_tick_continuous + delta * tick_hz, target_render_tick)
		if _render_tick_continuous > target_render_tick:
			_render_tick_continuous = target_render_tick

	var now := Time.get_ticks_usec() * 0.000001
	while (
		_remote_snapshots.size() >= 2 and
		float(_remote_snapshots[1].get("tick", -1)) <= _render_tick_continuous
	):
		_remote_snapshots.pop_front()

	if _remote_snapshots.size() >= 2:
		var from_snapshot := _remote_snapshots[0]
		var to_snapshot := _remote_snapshots[1]
		var from_tick := float(from_snapshot.get("tick", 0))
		var to_tick := float(to_snapshot.get("tick", 0))
		var alpha := 1.0
		if to_tick > from_tick:
			alpha = clampf((_render_tick_continuous - from_tick) / (to_tick - from_tick), 0.0, 1.0)
		_plane._apply_remote_pose(
			Vector3(from_snapshot["position"]).lerp(Vector3(to_snapshot["position"]), alpha),
			Quaternion(from_snapshot["rotation"]).slerp(Quaternion(to_snapshot["rotation"]), alpha)
		)
		return

	var latest_snapshot := _remote_snapshots[0]
	var latest_position := Vector3(latest_snapshot["position"])
	var latest_velocity := Vector3(latest_snapshot["linear_velocity"])
	var extrapolation := maxf(now - float(latest_snapshot["received_at"]), 0.0)
	_plane._apply_remote_pose(
		latest_position + latest_velocity * extrapolation,
		Quaternion(latest_snapshot["rotation"])
	)


func apply_spawn_state(character_position: Vector3, yaw: float) -> void:
	_plane.global_position = character_position
	_plane.rotation = Vector3(0.0, yaw, 0.0)
	_plane.reset_physics_interpolation()
	clear_state_for_spawn()


func clear_state_for_spawn() -> void:
	_remote_snapshots.clear()
	_prediction_history.clear()
	_correction_position = Vector3.ZERO
	_net_pending_input = {}
	_net_last_applied_input_seq = -1
	_net_ack_seq = -1
	_latest_server_tick = -1
	_render_tick_continuous = 0.0
	_render_tick_initialized = false
	_awaiting_first_shot_down_snapshot = false


func clear_remote_snapshots() -> void:
	_remote_snapshots.clear()
	_latest_server_tick = -1
	_render_tick_continuous = 0.0
	_render_tick_initialized = false
	_awaiting_first_shot_down_snapshot = false


func clear_prediction_correction() -> void:
	_prediction_history.clear()
	_correction_position = Vector3.ZERO


func begin_shot_down_remote_handoff() -> void:
	_awaiting_first_shot_down_snapshot = true
	_prediction_history.clear()
	_correction_position = Vector3.ZERO
	_seed_remote_snapshot_from_current_state()


func get_replicated_velocity() -> Vector3:
	if _plane._is_simulated_locally():
		return _plane.linear_velocity
	if not _remote_snapshots.is_empty():
		return Vector3(_remote_snapshots.back().get("linear_velocity", Vector3.ZERO))
	return _plane.linear_velocity


func build_state_for_batch(world_tick: int) -> Dictionary:
	var snapshot := {
		"tick": world_tick,
		"position": _plane.global_position,
		"rotation": _plane.global_transform.basis.orthonormalized().get_rotation_quaternion(),
		"linear_velocity": _plane.linear_velocity,
		"angular_velocity": _plane.angular_velocity,
	}
	if _plane._is_net_input_driven():
		snapshot["ack_seq"] = _net_ack_seq
	return snapshot


func _store_interpolation_snapshot(snapshot: Dictionary) -> void:
	var tick := int(snapshot.get("tick", -1))
	if tick >= 0 and not _remote_snapshots.is_empty():
		var latest_tick := int(_remote_snapshots.back().get("tick", -1))
		if tick <= latest_tick:
			return
	if tick >= 0:
		_latest_server_tick = tick

	var received_at := Time.get_ticks_usec() * 0.000001
	var stored_snapshot := {
		"tick": tick,
		"position": snapshot.get("position", _plane.global_position),
		"rotation": snapshot.get("rotation", _plane.global_transform.basis.get_rotation_quaternion()),
		"linear_velocity": snapshot.get("linear_velocity", Vector3.ZERO),
		"received_at": received_at,
	}
	_remote_snapshots.append(stored_snapshot)
	if not _render_tick_initialized and tick >= 0:
		var tick_hz := maxf(_plane.get_server_net_tick_hz(), 0.001)
		var interpolation_delay_ticks := maxf(ceil(REMOTE_INTERPOLATION_DELAY * tick_hz), 1.0)
		_render_tick_continuous = float(tick) - interpolation_delay_ticks
		_render_tick_initialized = true
	while _remote_snapshots.size() > REMOTE_MAX_SNAPSHOTS:
		_remote_snapshots.pop_front()


func _apply_first_shot_down_snapshot(snapshot: Dictionary) -> void:
	_awaiting_first_shot_down_snapshot = false
	_remote_snapshots.clear()
	_plane.global_position = Vector3(snapshot.get("position", _plane.global_position))
	_plane.global_basis = Basis(Quaternion(snapshot.get("rotation", Quaternion.IDENTITY)).normalized())
	_plane.linear_velocity = Vector3(snapshot.get("linear_velocity", _plane.linear_velocity))
	_plane.angular_velocity = Vector3(snapshot.get("angular_velocity", _plane.angular_velocity))
	_plane.reset_physics_interpolation()
	_store_interpolation_snapshot(snapshot)


func _seed_remote_snapshot_from_current_state() -> void:
	var seed_tick := _latest_server_tick
	if seed_tick < 0:
		seed_tick = 0
	var seed_snapshot := {
		"tick": seed_tick,
		"position": _plane.global_position,
		"rotation": _plane.global_transform.basis.orthonormalized().get_rotation_quaternion(),
		"linear_velocity": _plane.linear_velocity,
		"angular_velocity": _plane.angular_velocity,
	}
	_remote_snapshots.clear()
	_store_interpolation_snapshot(seed_snapshot)


func _reconcile_with_server_state(snapshot: Dictionary) -> void:
	var ack_seq := int(snapshot.get("ack_seq", -1))
	if ack_seq < 0:
		return

	var entry := _take_prediction_entry(ack_seq)
	if entry.is_empty():
		return

	var server_position := Vector3(snapshot.get("position", _plane.global_position))
	var server_rotation := Quaternion(snapshot.get("rotation", Quaternion.IDENTITY)).normalized()
	var server_velocity := Vector3(snapshot.get("linear_velocity", Vector3.ZERO))
	var server_angular_velocity := Vector3(snapshot.get("angular_velocity", Vector3.ZERO))
	var position_error: Vector3 = server_position - Vector3(entry["position"])

	if position_error.length() > _plane.reconcile_hard_snap_distance:
		_plane.global_position = server_position
		_plane.global_basis = Basis(server_rotation)
		_plane.linear_velocity = server_velocity
		_plane.angular_velocity = server_angular_velocity
		_plane.reset_physics_interpolation()
		_prediction_history.clear()
		_correction_position = Vector3.ZERO
		return

	if position_error.length() > _plane.reconcile_position_tolerance:
		_correction_position = position_error
	else:
		_correction_position = Vector3.ZERO

	var entry_rotation := Quaternion(entry["rotation"]).normalized()
	var rotation_error_rad := entry_rotation.angle_to(server_rotation)
	if rotation_error_rad > deg_to_rad(RECONCILE_ROTATION_TOLERANCE_DEG):
		var rotation_offset := server_rotation * entry_rotation.inverse()
		var partial_offset := Quaternion.IDENTITY.slerp(rotation_offset, _plane.reconcile_rotation_blend)
		var current_rotation: Quaternion = _plane.global_transform.basis.orthonormalized().get_rotation_quaternion()
		_plane.global_basis = Basis((partial_offset * current_rotation).normalized())

	var velocity_error: Vector3 = server_velocity - Vector3(entry["linear_velocity"])
	if velocity_error.length() > RECONCILE_VELOCITY_TOLERANCE:
		_plane.linear_velocity += velocity_error * _plane.reconcile_velocity_blend

	var angular_velocity_error: Vector3 = server_angular_velocity - Vector3(entry.get("angular_velocity", Vector3.ZERO))
	if rad_to_deg(angular_velocity_error.length()) > RECONCILE_ANGULAR_VELOCITY_TOLERANCE_DEG:
		_plane.angular_velocity += angular_velocity_error * _plane.reconcile_velocity_blend


func _take_prediction_entry(ack_seq: int) -> Dictionary:
	while not _prediction_history.is_empty():
		var entry: Dictionary = _prediction_history.front()
		var entry_seq := int(entry["seq"])
		if entry_seq < ack_seq:
			_prediction_history.pop_front()
			continue
		if entry_seq == ack_seq:
			_prediction_history.pop_front()
			return entry
		break
	return {}
