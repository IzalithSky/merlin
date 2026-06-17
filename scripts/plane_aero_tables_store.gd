extends RefCounted

const SAVE_PATH := "user://plane_aero_tables.json"
const SAVE_VERSION := 4

# Named presets. Built-ins ship in the project (read-only); user presets are
# saved snapshots. The active config above (SAVE_PATH) is what the game flies.
const BUILTIN_PRESETS_DIR := "res://data/presets"
const USER_PRESETS_DIR := "user://presets"
const DEFAULT_PRESET_ID := "default"
const SOURCE_BUILTIN := "builtin"
const SOURCE_USER := "user"

# Single source of truth for the editable numeric plane parameters. Drives JSON
# (de)serialization, runtime application, MP sync, and the editor's spinboxes.
const PARAM_SPECS: Array[Dictionary] = [
	{"key": "max_thrust", "label": "Max thrust", "min": 0.0, "max": 100000.0, "step": 100.0},
	{"key": "max_pitch", "label": "Max pitch", "min": 0.0, "max": 10.0, "step": 0.05},
	{"key": "max_yaw", "label": "Max yaw", "min": 0.0, "max": 10.0, "step": 0.05},
	{"key": "max_roll", "label": "Max roll", "min": 0.0, "max": 10.0, "step": 0.05},
	{"key": "base_control_torque", "label": "Base control torque", "min": 0.0, "max": 200000.0, "step": 500.0},
	{"key": "reference_area", "label": "Reference area", "min": 0.0, "max": 200.0, "step": 0.5},
	{"key": "extra_linear_drag_linear_coefficient", "label": "Linear drag (xv)", "min": 0.0, "max": 100.0, "step": 0.01},
	{"key": "extra_linear_drag_quadratic_coefficient", "label": "Quadratic drag (xv2)", "min": 0.0, "max": 100.0, "step": 0.01},
]


static func load_payload() -> Dictionary:
	# The active config the game flies. On a fresh machine (no user file yet),
	# fall back to the built-in default preset.
	var payload := _read_json(SAVE_PATH)
	if payload.is_empty():
		return load_preset(SOURCE_BUILTIN, DEFAULT_PRESET_ID)
	return payload


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Could not open aero file %s (error %s)." % [path, FileAccess.get_open_error()])
		return {}

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		push_error("Aero file is not a Dictionary JSON payload: %s." % path)
		return {}

	var payload: Dictionary = parsed
	return payload.duplicate(true)


static func preset_path(source: String, id: String) -> String:
	var dir := BUILTIN_PRESETS_DIR if source == SOURCE_BUILTIN else USER_PRESETS_DIR
	return "%s/%s.json" % [dir, id]


static func load_preset(source: String, id: String) -> Dictionary:
	return _read_json(preset_path(source, id))


static func sanitize_id(name: String) -> String:
	var id := ""
	for character in name.strip_edges().to_lower():
		if (character >= "a" and character <= "z") or (character >= "0" and character <= "9"):
			id += character
		elif character == " " or character == "-" or character == "_":
			id += "_"
	while id.contains("__"):
		id = id.replace("__", "_")
	return id.lstrip("_").rstrip("_")


static func list_presets() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	_append_preset_entries(entries, SOURCE_BUILTIN, BUILTIN_PRESETS_DIR)
	_append_preset_entries(entries, SOURCE_USER, USER_PRESETS_DIR)
	return entries


static func _append_preset_entries(entries: Array[Dictionary], source: String, dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return

	var file_names := dir.get_files()
	file_names.sort()
	for file_name in file_names:
		if not file_name.ends_with(".json"):
			continue
		var id := file_name.get_basename()
		var payload := _read_json("%s/%s" % [dir_path, file_name])
		var display_name: String = payload.get("name", id)
		entries.append({"source": source, "id": id, "name": display_name})


static func save_user_preset(display_name: String, payload: Dictionary) -> Dictionary:
	var id := sanitize_id(display_name)
	if id.is_empty():
		push_error("Cannot save preset with empty name.")
		return {}

	if not DirAccess.dir_exists_absolute(USER_PRESETS_DIR):
		DirAccess.make_dir_recursive_absolute(USER_PRESETS_DIR)

	var stored := payload.duplicate(true)
	stored["name"] = display_name.strip_edges()
	stored["source"] = SOURCE_USER
	stored["id"] = id
	stored["version"] = SAVE_VERSION

	var path := preset_path(SOURCE_USER, id)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not save preset to %s (error %s)." % [path, FileAccess.get_open_error()])
		return {}

	file.store_string(JSON.stringify(stored, "\t"))
	return {"source": SOURCE_USER, "id": id, "name": stored["name"]}


static func delete_user_preset(id: String) -> Error:
	var path := preset_path(SOURCE_USER, id)
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	return DirAccess.remove_absolute(path)


static func save_payload(payload: Dictionary) -> Error:
	var stored := payload.duplicate(true)
	stored["version"] = SAVE_VERSION

	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		var open_error: Error = FileAccess.get_open_error()
		push_error("Could not save aero tables to %s (error %s)." % [SAVE_PATH, open_error])
		return open_error

	file.store_string(JSON.stringify(stored, "\t"))
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
