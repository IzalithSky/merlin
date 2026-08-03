class_name PlaneMotionState
extends RefCounted

var transform: Transform3D = Transform3D.IDENTITY
var linear_velocity: Vector3 = Vector3.ZERO
var angular_velocity: Vector3 = Vector3.ZERO
var is_shot_down := false
var last_ground_impact_time := -INF


static func from_plane(plane):
	var state = load("res://scripts/plane_motion_state.gd").new()
	state.transform = plane.global_transform
	state.linear_velocity = plane.linear_velocity
	state.angular_velocity = plane.angular_velocity
	state.is_shot_down = bool(plane.get("is_shot_down"))
	if plane.has_method("get_last_ground_impact_time"):
		state.last_ground_impact_time = float(plane.call("get_last_ground_impact_time"))
	return state


func duplicate_state():
	var state = get_script().new()
	state.transform = transform
	state.linear_velocity = linear_velocity
	state.angular_velocity = angular_velocity
	state.is_shot_down = is_shot_down
	state.last_ground_impact_time = last_ground_impact_time
	return state


func apply_to_plane(plane) -> void:
	plane.global_transform = transform
	plane.linear_velocity = linear_velocity
	plane.angular_velocity = angular_velocity
	plane.set("is_shot_down", is_shot_down)
	if plane.has_method("set_last_ground_impact_time"):
		plane.call("set_last_ground_impact_time", last_ground_impact_time)


func to_dictionary() -> Dictionary:
	return {
		"transform": transform,
		"linear_velocity": linear_velocity,
		"angular_velocity": angular_velocity,
		"is_shot_down": is_shot_down,
		"last_ground_impact_time": last_ground_impact_time,
	}


static func from_dictionary(payload: Dictionary):
	var state = load("res://scripts/plane_motion_state.gd").new()
	state.transform = Transform3D(payload.get("transform", Transform3D.IDENTITY))
	state.linear_velocity = Vector3(payload.get("linear_velocity", Vector3.ZERO))
	state.angular_velocity = Vector3(payload.get("angular_velocity", Vector3.ZERO))
	state.is_shot_down = bool(payload.get("is_shot_down", false))
	state.last_ground_impact_time = float(payload.get("last_ground_impact_time", -INF))
	return state
