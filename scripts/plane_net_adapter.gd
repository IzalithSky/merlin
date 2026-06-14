class_name PlaneNetAdapter
extends RefCounted

const REMOTE_INTERPOLATION_DELAY := 0.1
# Must retain more history than the interpolation delay spans, or the playhead
# (latest - delay_ticks) sits at/below the oldest buffered snapshot and the lerp
# is pinned at alpha=0 (no smoothing). Delay is 3 ticks @30Hz; keep generous
# margin to also absorb snapshot delivery jitter.
const REMOTE_MAX_SNAPSHOTS := 16
const NET_INPUT_QUEUE_MAX := 4
const NET_INPUT_GAP_RESYNC_TICKS := 2
const PREDICTION_HISTORY_MAX := 180
const RECONCILE_VELOCITY_TOLERANCE := 1.0
const RECONCILE_ANGULAR_VELOCITY_TOLERANCE_DEG := 20.0
const RECONCILE_ROTATION_TOLERANCE_DEG := 10.0

var _plane
var _remote_snapshots: Array[Dictionary] = []
var _net_input_seq := 0
# Server-side jitter buffer of received client inputs, ordered by seq and drained
# one per physics tick. Replaces the old "keep only newest" pending slot, which
# dropped/skipped inputs whenever >1 arrived in a single server poll.
var _net_input_queue: Array[Dictionary] = []
var _net_last_applied_input_seq := -1
var _net_ack_seq := -1
var _net_gap_ticks := 0
var _prediction_history: Array[Dictionary] = []
var _probe_prev_vy := 0.0
var _correction_position := Vector3.ZERO
var _latest_server_tick := -1
var _render_tick_continuous := 0.0
var _render_tick_initialized := false
var _awaiting_first_shot_down_snapshot := false


func _init(plane) -> void:
	_plane = plane


func apply_net_control_input(input: Dictionary) -> void:
	var input_seq := int(input.get("seq", -1))
	# Reject already-applied or out-of-order arrivals (older than the queue tail).
	var queue_tail_seq := -1
	if not _net_input_queue.is_empty():
		queue_tail_seq = int(_net_input_queue.back().get("seq", -1))
	var accepted := input_seq > _net_last_applied_input_seq and input_seq > queue_tail_seq
	var dropped_overflow := false
	if accepted:
		_net_input_queue.append(input)
		# Bound added input latency: keep only a short runway of future inputs so
		# the server does not simulate a stale control stream under bursty arrival.
		while _net_input_queue.size() > NET_INPUT_QUEUE_MAX:
			_net_input_queue.pop_front()
			dropped_overflow = true
	NetProbe.log_line("INPUT_RECV", "peer=%d seq=%d last_applied=%d qlen=%d accepted=%s overflow=%s" % [
		_plane.peer_id, input_seq, _net_last_applied_input_seq,
		_net_input_queue.size(), str(accepted), str(dropped_overflow),
	])


func consume_pending_input() -> Dictionary:
	# Latch the ack before consuming a newer input: the body state this tick was
	# integrated from the previously applied seq.
	_net_ack_seq = _net_last_applied_input_seq
	if _net_input_queue.is_empty():
		_net_gap_ticks = 0
		# gap=1: no buffered input this tick; server holds the last input while
		# the predicting client advanced. Should be rare now (only real loss/starvation).
		NetProbe.log_line("INPUT_CONSUME", "peer=%d consumed=-1 last_applied=%d delta=0 gap=1 qlen=0" % [
			_plane.peer_id, _net_last_applied_input_seq,
		])
		return {}

	while not _net_input_queue.is_empty():
		var stale_seq := int(_net_input_queue.front().get("seq", -1))
		if stale_seq > _net_last_applied_input_seq:
			break
		_net_input_queue.pop_front()

	if _net_input_queue.is_empty():
		_net_gap_ticks = 0
		return {}

	var expected_seq := _net_last_applied_input_seq + 1
	var head_input: Dictionary = _net_input_queue.front()
	var head_seq := int(head_input.get("seq", -1))
	if _net_last_applied_input_seq >= 0 and head_seq > expected_seq:
		_net_gap_ticks += 1
		if _net_gap_ticks < NET_INPUT_GAP_RESYNC_TICKS and _net_input_queue.size() < NET_INPUT_QUEUE_MAX:
			NetProbe.log_line("INPUT_CONSUME", "peer=%d consumed=-1 last_applied=%d delta=0 gap=1 qlen=%d expected=%d head=%d" % [
				_plane.peer_id, _net_last_applied_input_seq, _net_input_queue.size(), expected_seq, head_seq,
			])
			return {}
		# Permanent gap recovery after repeated starvation / overflow pressure.
		expected_seq = head_seq

	_net_gap_ticks = 0
	var input: Dictionary = _net_input_queue.pop_front()
	var input_seq := int(input.get("seq", -1))

	var prev_applied := _net_last_applied_input_seq
	_net_last_applied_input_seq = input_seq
	# delta>1: intermediate seqs were skipped (now only via overflow drops).
	NetProbe.log_line("INPUT_CONSUME", "peer=%d consumed=%d last_applied=%d delta=%d gap=0 qlen=%d" % [
		_plane.peer_id, input_seq, prev_applied, input_seq - prev_applied, _net_input_queue.size(),
	])
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
		"effective_pitch": _plane._get_effective_pitch_input(),
		"aoa_deg": _plane.get_aoa_deg(),
		"local_ang_vel": _plane.get_local_angular_velocity(),
		"pitch_assist": _plane.is_pitch_assist_enabled(),
		"stabilization_assist": _plane.is_stabilization_assist_enabled(),
		"relative_roll_active": _plane.is_relative_roll_active(),
	})
	var local_ang_vel: Vector3 = _plane.get_local_angular_velocity()
	var probe_vy: float = _plane.linear_velocity.y
	var probe_dvy: float = probe_vy - _probe_prev_vy
	_probe_prev_vy = probe_vy
	var probe_airspeed: float = _plane.linear_velocity.length()
	NetProbe.log_line("PRED_STATE", "peer=%d seq=%d pos=(%.3f,%.3f,%.3f) vel=(%.3f,%.3f,%.3f) angvel=(%.3f,%.3f,%.3f) local_ang=(%.3f,%.3f,%.3f) eff_pitch=%.3f aoa=%.3f pitch_assist=%s stab=%s rel_roll=%s airspeed=%.2f dvy=%.4f" % [
		_plane.peer_id,
		_net_input_seq,
		_plane.global_position.x, _plane.global_position.y, _plane.global_position.z,
		_plane.linear_velocity.x, _plane.linear_velocity.y, _plane.linear_velocity.z,
		_plane.angular_velocity.x, _plane.angular_velocity.y, _plane.angular_velocity.z,
		local_ang_vel.x, local_ang_vel.y, local_ang_vel.z,
		_plane._get_effective_pitch_input(),
		_plane.get_aoa_deg(),
		str(_plane.is_pitch_assist_enabled()),
		str(_plane.is_stabilization_assist_enabled()),
		str(_plane.is_relative_roll_active()),
		probe_airspeed, probe_dvy,
	])
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
	var tick := int(snapshot.get("tick", -1))
	if tick >= 0:
		_latest_server_tick = tick

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

	var probe_prev_pos: Vector3 = _plane.global_position
	var tick_hz := maxf(_plane.get_server_net_tick_hz(), 0.001)
	var interpolation_delay_ticks := maxf(ceil(REMOTE_INTERPOLATION_DELAY * tick_hz), 1.0)
	var target_render_tick := float(_latest_server_tick) - interpolation_delay_ticks
	var probe_clamped := false
	if not _render_tick_initialized:
		_render_tick_continuous = target_render_tick
		_render_tick_initialized = true
	else:
		var probe_unclamped := _render_tick_continuous + delta * tick_hz
		_render_tick_continuous = minf(probe_unclamped, target_render_tick)
		# clamped=1: the playhead wanted to advance past the newest available data
		# and got pinned to the ceiling this frame -> a stall (no forward motion).
		probe_clamped = probe_unclamped >= target_render_tick - 0.0001
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
		_probe_interp("interp", probe_prev_pos, delta, target_render_tick, tick_hz, probe_clamped, alpha)
		return

	var latest_snapshot := _remote_snapshots[0]
	var latest_position := Vector3(latest_snapshot["position"])
	var latest_velocity := Vector3(latest_snapshot["linear_velocity"])
	var extrapolation := maxf(now - float(latest_snapshot["received_at"]), 0.0)
	_plane._apply_remote_pose(
		latest_position + latest_velocity * extrapolation,
		Quaternion(latest_snapshot["rotation"])
	)
	_probe_interp("extrap", probe_prev_pos, delta, target_render_tick, tick_hz, probe_clamped, 1.0)


func _probe_interp(mode: String, prev_pos: Vector3, delta: float, target_render_tick: float, tick_hz: float, clamped: bool, alpha: float) -> void:
	# rendered_speed is the actual per-frame visual speed of the remote body; a
	# stable value = smooth, a fluctuating one = jitter. Compare against the
	# steady ground-truth (the plane's replicated velocity magnitude).
	var rendered_speed: float = (_plane.global_position - prev_pos).length() / maxf(delta, 0.000001)
	NetProbe.log_line("INTERP", "peer=%d bot_peer=%s mode=%s dt=%.4f advance_ticks=%.3f render_tick=%.3f target=%.3f latest=%d clamped=%s buf=%d alpha=%.3f rspeed=%.2f" % [
		_plane.peer_id, str(_plane.is_bot_peer), mode, delta, delta * tick_hz, _render_tick_continuous,
		target_render_tick, _latest_server_tick, str(clamped),
		_remote_snapshots.size(), alpha, rendered_speed,
	])


func apply_spawn_state(character_position: Vector3, yaw: float) -> void:
	_plane.global_position = character_position
	_plane.rotation = Vector3(0.0, yaw, 0.0)
	_plane.reset_physics_interpolation()
	clear_state_for_spawn()


func clear_state_for_spawn() -> void:
	_remote_snapshots.clear()
	_prediction_history.clear()
	_correction_position = Vector3.ZERO
	_net_input_queue.clear()
	_net_last_applied_input_seq = -1
	_net_ack_seq = -1
	_net_gap_ticks = 0
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
		snapshot["ack_seq"] = _net_last_applied_input_seq
		var local_ang_vel: Vector3 = _plane.get_local_angular_velocity()
		var probe_vy: float = _plane.linear_velocity.y
		var probe_dvy: float = probe_vy - _probe_prev_vy
		_probe_prev_vy = probe_vy
		var probe_airspeed: float = _plane.linear_velocity.length()
		NetProbe.log_line("AUTH_STATE", "peer=%d ack=%d applied=%d pos=(%.3f,%.3f,%.3f) vel=(%.3f,%.3f,%.3f) angvel=(%.3f,%.3f,%.3f) local_ang=(%.3f,%.3f,%.3f) eff_pitch=%.3f aoa=%.3f pitch_assist=%s stab=%s rel_roll=%s airspeed=%.2f dvy=%.4f" % [
			_plane.peer_id,
			_net_last_applied_input_seq,
			_net_last_applied_input_seq,
			_plane.global_position.x, _plane.global_position.y, _plane.global_position.z,
			_plane.linear_velocity.x, _plane.linear_velocity.y, _plane.linear_velocity.z,
			_plane.angular_velocity.x, _plane.angular_velocity.y, _plane.angular_velocity.z,
			local_ang_vel.x, local_ang_vel.y, local_ang_vel.z,
			_plane._get_effective_pitch_input(),
			_plane.get_aoa_deg(),
			str(_plane.is_pitch_assist_enabled()),
			str(_plane.is_stabilization_assist_enabled()),
			str(_plane.is_relative_roll_active()),
			probe_airspeed, probe_dvy,
		])
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
	var prev_snapshot: Dictionary = {}
	if not _remote_snapshots.is_empty():
		prev_snapshot = _remote_snapshots.back()
	var stored_snapshot := {
		"tick": tick,
		"position": snapshot.get("position", _plane.global_position),
		"rotation": snapshot.get("rotation", _plane.global_transform.basis.get_rotation_quaternion()),
		"linear_velocity": snapshot.get("linear_velocity", Vector3.ZERO),
		"received_at": received_at,
	}
	if not prev_snapshot.is_empty():
		var prev_tick := int(prev_snapshot.get("tick", -1))
		var dt_ticks := tick - prev_tick
		var prev_pos := Vector3(prev_snapshot.get("position", _plane.global_position))
		var curr_pos := Vector3(stored_snapshot.get("position", _plane.global_position))
		var pos_delta := curr_pos - prev_pos
		var obs_speed: float = pos_delta.length() * _plane.get_server_net_tick_hz() / maxf(float(dt_ticks), 1.0)
		var vel_mag: float = Vector3(stored_snapshot.get("linear_velocity", Vector3.ZERO)).length()
		var vel_prev_mag: float = Vector3(prev_snapshot.get("linear_velocity", Vector3.ZERO)).length()
		var vel_jump: float = (Vector3(stored_snapshot.get("linear_velocity", Vector3.ZERO)) - Vector3(prev_snapshot.get("linear_velocity", Vector3.ZERO))).length()
		var heading_delta_deg: float = 0.0
		if pos_delta.length_squared() > 0.000001 and vel_mag > 0.000001:
			heading_delta_deg = rad_to_deg(pos_delta.normalized().angle_to(Vector3(stored_snapshot.get("linear_velocity", Vector3.ZERO)).normalized()))
		NetProbe.log_line("SNAP_ENTITY", "peer=%d bot_peer=%s dt_ticks=%d pos_step=%.3f obs_speed=%.3f vel_mag=%.3f vel_prev_mag=%.3f vel_jump=%.3f heading_delta_deg=%.3f" % [
			_plane.peer_id,
			str(_plane.is_bot_peer),
			dt_ticks,
			pos_delta.length(),
			obs_speed,
			vel_mag,
			vel_prev_mag,
			vel_jump,
			heading_delta_deg,
		])
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
	_render_tick_continuous = 0.0
	_render_tick_initialized = false
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

	var server_position := Vector3(snapshot.get("position", _plane.global_position))
	var server_rotation := Quaternion(snapshot.get("rotation", Quaternion.IDENTITY)).normalized()
	var server_velocity := Vector3(snapshot.get("linear_velocity", Vector3.ZERO))
	var server_angular_velocity := Vector3(snapshot.get("angular_velocity", Vector3.ZERO))
	var best_seq := _probe_reconcile_phase_window(ack_seq, server_position, server_rotation, server_velocity, server_angular_velocity)

	var entry := _take_prediction_entry(best_seq)
	if entry.is_empty():
		NetProbe.log_line("RECON", "peer=%d ack=%d best=%d miss=1 hist=%d" % [
			_plane.peer_id, ack_seq, best_seq, _prediction_history.size(),
		])
		return

	var position_error: Vector3 = server_position - Vector3(entry["position"])

	var probe_entry_rotation := Quaternion(entry["rotation"]).normalized()
	var probe_rot_err_deg := rad_to_deg(probe_entry_rotation.angle_to(server_rotation))
	var probe_vel_err := (server_velocity - Vector3(entry["linear_velocity"])).length()
	var probe_ang_vel_err := rad_to_deg((server_angular_velocity - Vector3(entry.get("angular_velocity", Vector3.ZERO))).length())
	var probe_pos_err := position_error.length()
	var probe_hard: bool = probe_pos_err > _plane.reconcile_hard_snap_distance
	var probe_corr: bool = probe_pos_err > _plane.reconcile_position_tolerance
	# pos_err is the steady-state divergence between client prediction and server
	# at the acked seq. At 0 ping this should sit near 0; large/persistent values
	# (above reconcile_position_tolerance) mean corrections fire every snapshot
	# -> local jitter.
	var probe_vel_err_vec: Vector3 = server_velocity - Vector3(entry["linear_velocity"])
	var probe_ang_vel_err_vec: Vector3 = server_angular_velocity - Vector3(entry.get("angular_velocity", Vector3.ZERO))
	var probe_entry_fwd: Vector3 = probe_entry_rotation * Vector3(0.0, 0.0, -1.0)
	var probe_pitch_deg := rad_to_deg(asin(clampf(probe_entry_fwd.y, -1.0, 1.0)))
	var probe_entry_airspeed := Vector3(entry["linear_velocity"]).length()
	NetProbe.log_line("RECON", "peer=%d ack=%d best=%d miss=0 pos_err=%.3f rot_err_deg=%.3f vel_err=%.3f vel_err_vec=(%.3f,%.3f,%.3f) ang_vel_err_deg=%.3f ang_vel_err_vec=(%.3f,%.3f,%.3f) eff_pitch=%.3f aoa=%.3f pitch_assist=%s stab=%s rel_roll=%s hard_snap=%s corr_set=%s hist=%d airspeed=%.2f pitch_deg=%.2f" % [
		_plane.peer_id, ack_seq, best_seq, probe_pos_err, probe_rot_err_deg, probe_vel_err,
		probe_vel_err_vec.x, probe_vel_err_vec.y, probe_vel_err_vec.z,
		probe_ang_vel_err,
		probe_ang_vel_err_vec.x, probe_ang_vel_err_vec.y, probe_ang_vel_err_vec.z,
		float(entry.get("effective_pitch", 0.0)),
		float(entry.get("aoa_deg", 0.0)),
		str(bool(entry.get("pitch_assist", false))),
		str(bool(entry.get("stabilization_assist", false))),
		str(bool(entry.get("relative_roll_active", false))),
		str(probe_hard), str(probe_corr), _prediction_history.size(),
		probe_entry_airspeed, probe_pitch_deg,
	])

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


func _probe_reconcile_phase_window(
	ack_seq: int,
	server_position: Vector3,
	server_rotation: Quaternion,
	server_velocity: Vector3,
	server_angular_velocity: Vector3
) -> int:
	var offsets := PackedInt32Array([-1, 0, 1])
	var parts: Array[String] = []
	var best_seq := ack_seq
	var best_pos_err := INF
	for offset in offsets:
		var seq := ack_seq + offset
		var entry := _find_prediction_entry(seq)
		if entry.is_empty():
			parts.append("seq%d=na" % seq)
			continue
		var pos_err := (server_position - Vector3(entry["position"])).length()
		var rot_err_deg := rad_to_deg(Quaternion(entry["rotation"]).normalized().angle_to(server_rotation))
		var vel_err := (server_velocity - Vector3(entry["linear_velocity"])).length()
		var ang_err_deg := rad_to_deg((server_angular_velocity - Vector3(entry.get("angular_velocity", Vector3.ZERO))).length())
		if pos_err < best_pos_err:
			best_pos_err = pos_err
			best_seq = seq
		parts.append(
			"seq%d_pos=%.3f seq%d_rot=%.3f seq%d_vel=%.3f seq%d_ang=%.3f" % [
				seq, pos_err, seq, rot_err_deg, seq, vel_err, seq, ang_err_deg,
			]
		)
	NetProbe.log_line("RECON_PHASE", "peer=%d ack=%d best_seq=%d %s" % [
		_plane.peer_id, ack_seq, best_seq, " ".join(parts),
	])
	return best_seq


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


func _find_prediction_entry(target_seq: int) -> Dictionary:
	for entry_variant in _prediction_history:
		var entry: Dictionary = entry_variant
		if int(entry.get("seq", -1)) == target_seq:
			return entry
	return {}
