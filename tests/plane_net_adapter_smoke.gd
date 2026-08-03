extends SceneTree

const PLANE_NET_ADAPTER := preload("res://scripts/plane_net_adapter.gd")

var _failed := false


class PlaneStub:
	extends RefCounted

	var is_local_player := false
	var global_position := Vector3.ZERO
	var global_basis := Basis.IDENTITY
	var linear_velocity := Vector3.ZERO
	var angular_velocity := Vector3.ZERO

	var global_transform: Transform3D:
		get:
			return Transform3D(global_basis, global_position)

	func _is_simulated_locally() -> bool:
		return false

	func _is_predicting_client() -> bool:
		return false

	func _is_net_input_driven() -> bool:
		return false

	func get_server_net_tick_hz() -> float:
		return 10.0

	func _apply_remote_pose(remote_position: Vector3, rotation_quaternion: Quaternion) -> void:
		global_position = remote_position
		global_basis = Basis(rotation_quaternion.normalized())


func _init() -> void:
	_test_single_snapshot_holds_authoritative_pose()
	_test_two_snapshots_interpolate_by_server_tick()
	_test_old_snapshots_are_ignored()
	_test_server_input_queue_consumes_in_order()

	if not _failed:
		print("plane_net_adapter_smoke_ok")
		quit(0)


func _test_single_snapshot_holds_authoritative_pose() -> void:
	var plane := PlaneStub.new()
	var adapter := PLANE_NET_ADAPTER.new(plane)
	adapter.apply_remote_state({
		"tick": 10,
		"position": Vector3(10.0, 0.0, 0.0),
		"rotation": Quaternion.IDENTITY,
		"linear_velocity": Vector3(1000.0, 0.0, 0.0),
	})
	adapter.update_remote_interpolation(0.25)

	var debug_state := adapter.get_remote_interpolation_debug_state()
	_assert(_approx_vec3(plane.global_position, Vector3(10.0, 0.0, 0.0)), "single snapshot should hold pose")
	_assert(String(debug_state.get("display_mode", "")) == "hold", "single snapshot mode should be hold")
	_assert(_approx(float(debug_state.get("extrapolation_duration", -1.0)), 0.0), "hold should not extrapolate")


func _test_two_snapshots_interpolate_by_server_tick() -> void:
	var plane := PlaneStub.new()
	var adapter := PLANE_NET_ADAPTER.new(plane)
	adapter.apply_remote_state({
		"tick": 10,
		"position": Vector3.ZERO,
		"rotation": Quaternion.IDENTITY,
		"linear_velocity": Vector3.ZERO,
	})
	adapter.apply_remote_state({
		"tick": 20,
		"position": Vector3(100.0, 0.0, 0.0),
		"rotation": Quaternion.IDENTITY,
		"linear_velocity": Vector3.ZERO,
	})
	adapter.update_remote_interpolation(0.6)

	var debug_state := adapter.get_remote_interpolation_debug_state()
	_assert(_approx_vec3(plane.global_position, Vector3(50.0, 0.0, 0.0)), "two snapshots should interpolate by tick")
	_assert(String(debug_state.get("display_mode", "")) == "interpolate", "two snapshot mode should interpolate")
	_assert(int(debug_state.get("buffer_length", 0)) == 2, "interpolation buffer should keep both snapshots")


func _test_old_snapshots_are_ignored() -> void:
	var plane := PlaneStub.new()
	var adapter := PLANE_NET_ADAPTER.new(plane)
	adapter.apply_remote_state({
		"tick": 10,
		"position": Vector3(10.0, 0.0, 0.0),
		"rotation": Quaternion.IDENTITY,
		"linear_velocity": Vector3.ZERO,
	})
	adapter.apply_remote_state({
		"tick": 9,
		"position": Vector3(9.0, 0.0, 0.0),
		"rotation": Quaternion.IDENTITY,
		"linear_velocity": Vector3.ZERO,
	})

	var debug_state := adapter.get_remote_interpolation_debug_state()
	_assert(int(debug_state.get("buffer_length", 0)) == 1, "old snapshot should be ignored")
	_assert(int(debug_state.get("latest_server_tick", -1)) == 10, "latest tick should remain newest accepted tick")


func _test_server_input_queue_consumes_in_order() -> void:
	var plane := PlaneStub.new()
	var adapter := PLANE_NET_ADAPTER.new(plane)
	adapter.apply_net_control_input({"seq": 1, "msec": 16})
	adapter.apply_net_control_input({"seq": 2, "msec": 17})
	adapter.apply_net_control_input({"seq": 2, "msec": 17})
	adapter.apply_net_control_input({"seq": 1, "msec": 16})

	var debug_state := adapter.get_input_debug_state()
	_assert(int(debug_state.get("queue_length", 0)) == 2, "input queue should reject duplicate/old frames")

	var first_input := adapter.consume_pending_input()
	var second_input := adapter.consume_pending_input()
	var empty_input := adapter.consume_pending_input()
	debug_state = adapter.get_input_debug_state()
	_assert(int(first_input.get("seq", -1)) == 1, "first queued input should be seq 1")
	_assert(int(second_input.get("seq", -1)) == 2, "second queued input should be seq 2")
	_assert(empty_input.is_empty(), "input queue should be empty after ordered consumption")
	_assert(int(debug_state.get("last_applied_msec", -1)) == 17, "last msec should track consumed input")
	_assert(int(debug_state.get("ack_seq", -1)) == 2, "ack should track last consumed input")


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error(message)
	quit(1)


func _approx(value: float, expected: float) -> bool:
	return absf(value - expected) <= 0.0001


func _approx_vec3(value: Vector3, expected: Vector3) -> bool:
	return value.distance_to(expected) <= 0.0001
