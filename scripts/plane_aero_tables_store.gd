extends RefCounted

const SAVE_PATH := "user://plane_aero_tables.json"
const SAVE_VERSION := 3


static func load_payload() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {}

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_error("Could not open aero tables file %s (error %s)." % [SAVE_PATH, FileAccess.get_open_error()])
		return {}

	var raw_json := file.get_as_text()
	var parsed: Variant = JSON.parse_string(raw_json)
	if not parsed is Dictionary:
		push_error("Aero tables file is not a Dictionary JSON payload: %s." % SAVE_PATH)
		return {}

	var payload: Dictionary = parsed
	return payload.duplicate(true)


static func save_payload(
	lift_points: Array[Vector2],
	drag_points: Array[Vector2],
	control_authority_points: Array[Vector2],
	thrust_points: Array[Vector2]
) -> Error:
	var payload: Dictionary = {
		"version": SAVE_VERSION,
		"lift_table": encode_points(lift_points),
		"drag_table": encode_points(drag_points),
		"control_authority_table": encode_points(control_authority_points),
		"thrust_table": encode_points(thrust_points),
	}

	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		var open_error: Error = FileAccess.get_open_error()
		push_error("Could not save aero tables to %s (error %s)." % [SAVE_PATH, open_error])
		return open_error

	file.store_string(JSON.stringify(payload, "\t"))
	return OK


static func encode_points(points: Array[Vector2]) -> Array:
	var encoded: Array = []
	for point: Vector2 in points:
		encoded.append({
			"x": point.x,
			"y": point.y,
		})
	return encoded


static func decode_points(raw_points: Variant) -> Array[Vector2]:
	var points: Array[Vector2] = []
	if not raw_points is Array:
		return points

	var source_points: Array = raw_points
	for raw_point: Variant in source_points:
		if raw_point is Vector2:
			points.append(raw_point)
			continue

		if raw_point is Dictionary:
			var point_dict: Dictionary = raw_point
			if point_dict.has("x") and point_dict.has("y"):
				var x_value: float = float(point_dict["x"])
				var y_value: float = float(point_dict["y"])
				points.append(Vector2(x_value, y_value))
			continue

		if raw_point is Array:
			var point_array: Array = raw_point
			if point_array.size() >= 2:
				var px: float = float(point_array[0])
				var py: float = float(point_array[1])
				points.append(Vector2(px, py))

	return points
