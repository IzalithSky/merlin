extends RefCounted

## File cache for the sustained-turn AoA surface used by the sustain-turn limiter.
## The surface build is expensive, so results are keyed by a content signature
## (a hash of every aero input that affects the surface) and persisted to disk.
## Identical content reuses the cached file; changed content yields a new
## signature and is rebuilt. Only the fields the limiter looks up are stored.

const CACHE_DIR := "user://aoa_surface_cache"
# Bump when the surface builder's maths or sample layout changes so stale files
# (built by an older algorithm but same aero inputs) are ignored.
const CACHE_VERSION := 1


static func surface_path(signature: String) -> String:
	return "%s/%s.bin" % [CACHE_DIR, signature]


static func load_surface(signature: String) -> Dictionary:
	var path := surface_path(signature)
	if not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}

	var decoded: Variant = bytes_to_var(file.get_buffer(file.get_length()))
	if not (decoded is Dictionary):
		return {}

	var surface: Dictionary = decoded
	if (
		not surface.has("speed_values")
		or not surface.has("gamma_values")
		or not surface.has("value_values")
		or int(surface.get("speed_count", 0)) <= 0
	):
		return {}
	return surface


static func store_surface(signature: String, surface: Dictionary) -> void:
	if surface.is_empty():
		return

	if not DirAccess.dir_exists_absolute(CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(CACHE_DIR)

	# Persist only what the limiter samples (find_nearest_surface_cell); the dense
	# `points` array is for the 3D viewer and isn't needed here.
	var minimal := {
		"speed_values": surface.get("speed_values", PackedFloat32Array()),
		"gamma_values": surface.get("gamma_values", PackedFloat32Array()),
		"value_values": surface.get("value_values", PackedFloat32Array()),
		"speed_count": int(surface.get("speed_count", 0)),
		"gamma_count": int(surface.get("gamma_count", 0)),
		"value_key": String(surface.get("value_key", "aoa_deg")),
	}

	var file := FileAccess.open(surface_path(signature), FileAccess.WRITE)
	if file == null:
		push_warning("Could not write AoA surface cache: %s" % surface_path(signature))
		return
	file.store_buffer(var_to_bytes(minimal))
