extends SceneTree

const NET_WIRE := preload("res://scripts/net_wire.gd")

var _failed := false


func _init() -> void:
	var input := {
		"seq": 17,
		"roll": 0.25,
		"pitch": -0.5,
		"yaw": 0.75,
		"throttle": -0.125,
		"effective_pitch": -0.375,
		"pitch_control_active": true,
		"yaw_control_active": false,
		"direct_roll_control_active": true,
		"relative_roll_target_active": false,
		"pitch_assist_enabled": true,
		"stabilization_assist_enabled": false,
		"sustain_turn_mode_active": true,
	}
	var input_packet := NET_WIRE.encode_input(input)
	var decoded_input := NET_WIRE.decode_input(input_packet)
	_assert(not decoded_input.is_empty(), "decoded input should not be empty")
	_assert(int(decoded_input.get("seq", -1)) == 17, "seq round-trip failed")
	_assert(_approx(float(decoded_input.get("roll", 0.0)), 0.25), "roll round-trip failed")
	_assert(_approx(float(decoded_input.get("pitch", 0.0)), -0.5), "pitch round-trip failed")
	_assert(_approx(float(decoded_input.get("yaw", 0.0)), 0.75), "yaw round-trip failed")
	_assert(_approx(float(decoded_input.get("throttle", 0.0)), -0.125), "throttle round-trip failed")
	_assert(_approx(float(decoded_input.get("effective_pitch", 0.0)), -0.375), "effective_pitch round-trip failed")
	_assert(bool(decoded_input.get("pitch_control_active", false)), "pitch_control_active round-trip failed")
	_assert(not bool(decoded_input.get("yaw_control_active", true)), "yaw_control_active round-trip failed")
	_assert(bool(decoded_input.get("direct_roll_control_active", false)), "direct_roll_control_active round-trip failed")
	_assert(not bool(decoded_input.get("relative_roll_target_active", true)), "relative_roll_target_active round-trip failed")
	_assert(bool(decoded_input.get("pitch_assist_enabled", false)), "pitch_assist_enabled round-trip failed")
	_assert(not bool(decoded_input.get("stabilization_assist_enabled", true)), "stabilization_assist_enabled round-trip failed")
	_assert(bool(decoded_input.get("sustain_turn_mode_active", false)), "sustain_turn_mode_active round-trip failed")

	var planes: Array[Dictionary] = [
		{
			"peer_id": 1,
			"tick": 9,
			"position": Vector3(1.0, 2.0, 3.0),
			"linear_velocity": Vector3(-4.0, 5.0, -6.0),
			"angular_velocity": Vector3(0.1, -0.2, 0.3),
			"rotation": Quaternion(0.0, 0.70710677, 0.0, 0.70710677),
			"ack_seq": 15,
		},
		{
			"peer_id": 1000000,
			"tick": 9,
			"position": Vector3(-7.0, 8.0, -9.0),
			"linear_velocity": Vector3(10.0, -11.0, 12.0),
			"angular_velocity": Vector3(-0.4, 0.5, -0.6),
			"rotation": Quaternion(0.2, 0.3, 0.4, 0.84261495).normalized(),
			"ack_seq": -1,
		},
	]
	var snapshot_packet := NET_WIRE.encode_world_snapshot(9, planes)
	var decoded_snapshot := NET_WIRE.decode_world_snapshot(snapshot_packet)
	_assert(not decoded_snapshot.is_empty(), "decoded snapshot should not be empty")
	_assert(int(decoded_snapshot.get("tick", -1)) == 9, "world tick round-trip failed")
	var decoded_planes: Array = decoded_snapshot.get("planes", [])
	_assert(decoded_planes.size() == 2, "plane count round-trip failed")
	var decoded_first: Dictionary = decoded_planes[0]
	_assert(int(decoded_first.get("peer_id", -1)) == 1, "peer_id round-trip failed")
	_assert(_approx_vec3(Vector3(decoded_first.get("position", Vector3.ZERO)), Vector3(1.0, 2.0, 3.0)), "position round-trip failed")
	_assert(_approx_vec3(Vector3(decoded_first.get("linear_velocity", Vector3.ZERO)), Vector3(-4.0, 5.0, -6.0)), "linear_velocity round-trip failed")
	_assert(_approx_vec3(Vector3(decoded_first.get("angular_velocity", Vector3.ZERO)), Vector3(0.1, -0.2, 0.3)), "angular_velocity round-trip failed")
	_assert(_approx_quat(Quaternion(decoded_first.get("rotation", Quaternion.IDENTITY)), Quaternion(0.0, 0.70710677, 0.0, 0.70710677).normalized()), "rotation round-trip failed")
	_assert(int(decoded_first.get("ack_seq", 0)) == 15, "ack_seq round-trip failed")

	if not _failed:
		print("net_wire_smoke_ok input_bytes=%d snapshot_bytes=%d" % [input_packet.size(), snapshot_packet.size()])
		quit(0)


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


func _approx_quat(value: Quaternion, expected: Quaternion) -> bool:
	return value.angle_to(expected) <= 0.0001
