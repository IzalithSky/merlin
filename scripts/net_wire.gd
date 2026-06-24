class_name NetWire
extends RefCounted

const FORMAT_VERSION := 1

const INPUT_FLAG_PITCH_CONTROL_ACTIVE := 1 << 0
const INPUT_FLAG_YAW_CONTROL_ACTIVE := 1 << 1
const INPUT_FLAG_DIRECT_ROLL_CONTROL_ACTIVE := 1 << 2
const INPUT_FLAG_RELATIVE_ROLL_TARGET_ACTIVE := 1 << 3
const INPUT_FLAG_PITCH_ASSIST_ENABLED := 1 << 4
const INPUT_FLAG_STABILIZATION_ASSIST_ENABLED := 1 << 5
const INPUT_FLAG_SUSTAIN_TURN_MODE_ACTIVE := 1 << 6

const WORLD_HEADER_BYTES := 1 + 4 + 2
const WORLD_PLANE_BYTES := 4 + (9 * 4) + (4 * 4) + 4
const INPUT_BYTES := 1 + 4 + (5 * 4) + 1


static func encode_world_snapshot(world_tick: int, planes: Array[Dictionary]) -> PackedByteArray:
	var peer := StreamPeerBuffer.new()
	peer.clear()
	peer.put_u8(FORMAT_VERSION)
	peer.put_u32(world_tick)
	peer.put_u16(planes.size())
	for plane in planes:
		peer.put_32(int(plane.get("peer_id", -1)))
		var position := Vector3(plane.get("position", Vector3.ZERO))
		var linear_velocity := Vector3(plane.get("linear_velocity", Vector3.ZERO))
		var angular_velocity := Vector3(plane.get("angular_velocity", Vector3.ZERO))
		var rotation := Quaternion(plane.get("rotation", Quaternion.IDENTITY)).normalized()
		_put_vector3(peer, position)
		_put_vector3(peer, linear_velocity)
		_put_vector3(peer, angular_velocity)
		_put_quaternion(peer, rotation)
		peer.put_32(int(plane.get("ack_seq", -1)))
	return peer.data_array


static func decode_world_snapshot(data: PackedByteArray) -> Dictionary:
	if data.size() < WORLD_HEADER_BYTES:
		return {}

	var peer := StreamPeerBuffer.new()
	peer.data_array = data
	var version := peer.get_u8()
	if version != FORMAT_VERSION:
		return {}

	if peer.get_available_bytes() < 6:
		return {}

	var world_tick := int(peer.get_u32())
	var plane_count := int(peer.get_u16())
	if peer.get_available_bytes() < plane_count * WORLD_PLANE_BYTES:
		return {}

	var planes: Array[Dictionary] = []
	for _plane_index in range(plane_count):
		var peer_id := int(peer.get_32())
		var position := _get_vector3(peer)
		var linear_velocity := _get_vector3(peer)
		var angular_velocity := _get_vector3(peer)
		var rotation := _get_quaternion(peer).normalized()
		var ack_seq := int(peer.get_32())
		planes.append({
			"peer_id": peer_id,
			"tick": world_tick,
			"position": position,
			"linear_velocity": linear_velocity,
			"angular_velocity": angular_velocity,
			"rotation": rotation,
			"ack_seq": ack_seq,
		})

	return {
		"tick": world_tick,
		"planes": planes,
	}


static func encode_input(input: Dictionary) -> PackedByteArray:
	var peer := StreamPeerBuffer.new()
	peer.clear()
	peer.put_u8(FORMAT_VERSION)
	peer.put_32(int(input.get("seq", -1)))
	peer.put_float(float(input.get("roll", 0.0)))
	peer.put_float(float(input.get("pitch", 0.0)))
	peer.put_float(float(input.get("yaw", 0.0)))
	peer.put_float(float(input.get("throttle", -1.0)))
	peer.put_float(float(input.get("effective_pitch", 0.0)))
	peer.put_u8(_encode_input_flags(input))
	return peer.data_array


static func decode_input(data: PackedByteArray) -> Dictionary:
	if data.size() < INPUT_BYTES:
		return {}

	var peer := StreamPeerBuffer.new()
	peer.data_array = data
	var version := peer.get_u8()
	if version != FORMAT_VERSION:
		return {}
	if peer.get_available_bytes() < INPUT_BYTES - 1:
		return {}

	var seq := int(peer.get_32())
	var roll := peer.get_float()
	var pitch := peer.get_float()
	var yaw := peer.get_float()
	var throttle := peer.get_float()
	var effective_pitch := peer.get_float()
	var flags := peer.get_u8()
	return {
		"seq": seq,
		"roll": roll,
		"pitch": pitch,
		"yaw": yaw,
		"throttle": throttle,
		"effective_pitch": effective_pitch,
		"pitch_control_active": bool(flags & INPUT_FLAG_PITCH_CONTROL_ACTIVE),
		"yaw_control_active": bool(flags & INPUT_FLAG_YAW_CONTROL_ACTIVE),
		"direct_roll_control_active": bool(flags & INPUT_FLAG_DIRECT_ROLL_CONTROL_ACTIVE),
		"relative_roll_target_active": bool(flags & INPUT_FLAG_RELATIVE_ROLL_TARGET_ACTIVE),
		"pitch_assist_enabled": bool(flags & INPUT_FLAG_PITCH_ASSIST_ENABLED),
		"stabilization_assist_enabled": bool(flags & INPUT_FLAG_STABILIZATION_ASSIST_ENABLED),
		"sustain_turn_mode_active": bool(flags & INPUT_FLAG_SUSTAIN_TURN_MODE_ACTIVE),
	}


static func _encode_input_flags(input: Dictionary) -> int:
	var flags := 0
	if bool(input.get("pitch_control_active", false)):
		flags |= INPUT_FLAG_PITCH_CONTROL_ACTIVE
	if bool(input.get("yaw_control_active", false)):
		flags |= INPUT_FLAG_YAW_CONTROL_ACTIVE
	if bool(input.get("direct_roll_control_active", false)):
		flags |= INPUT_FLAG_DIRECT_ROLL_CONTROL_ACTIVE
	if bool(input.get("relative_roll_target_active", false)):
		flags |= INPUT_FLAG_RELATIVE_ROLL_TARGET_ACTIVE
	if bool(input.get("pitch_assist_enabled", true)):
		flags |= INPUT_FLAG_PITCH_ASSIST_ENABLED
	if bool(input.get("stabilization_assist_enabled", true)):
		flags |= INPUT_FLAG_STABILIZATION_ASSIST_ENABLED
	if bool(input.get("sustain_turn_mode_active", false)):
		flags |= INPUT_FLAG_SUSTAIN_TURN_MODE_ACTIVE
	return flags


static func _put_vector3(peer: StreamPeerBuffer, value: Vector3) -> void:
	peer.put_float(value.x)
	peer.put_float(value.y)
	peer.put_float(value.z)


static func _get_vector3(peer: StreamPeerBuffer) -> Vector3:
	return Vector3(peer.get_float(), peer.get_float(), peer.get_float())


static func _put_quaternion(peer: StreamPeerBuffer, value: Quaternion) -> void:
	peer.put_float(value.x)
	peer.put_float(value.y)
	peer.put_float(value.z)
	peer.put_float(value.w)


static func _get_quaternion(peer: StreamPeerBuffer) -> Quaternion:
	return Quaternion(peer.get_float(), peer.get_float(), peer.get_float(), peer.get_float())
