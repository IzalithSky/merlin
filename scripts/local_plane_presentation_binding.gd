class_name LocalPlanePresentationBinding
extends RefCounted

const LOCAL_PLANE_CAMERA_RIG_SCENE := preload("res://scenes/local_plane_camera_rig.tscn")
const PLANE_TELEMETRY_HUD_SCENE := preload("res://scenes/plane_telemetry_hud.tscn")
const PLANE_TARGETING_HUD_SCENE := preload("res://scenes/plane_targeting_hud.tscn")

var _owner: Node
var _camera_rig
var _hud
var _targeting_hud


func _init(owner: Node) -> void:
	_owner = owner


func bind(character: Node3D) -> void:
	_ensure_nodes()
	_camera_rig.set_target(character)
	_hud.set_target(character)
	var camera: Camera3D = _camera_rig.get_camera()
	_hud.set_camera(camera)
	_targeting_hud.set_target(character)
	_targeting_hud.set_camera(camera)

	var detached_callback := Callable(_hud, "on_camera_rig_detached")
	if not _camera_rig.detached.is_connected(detached_callback):
		_camera_rig.detached.connect(detached_callback)


func clear() -> void:
	if _camera_rig != null:
		_camera_rig.set_target(null)
	if _hud != null:
		_hud.set_target(null)
		_hud.set_camera(null)
	if _targeting_hud != null:
		_targeting_hud.set_target(null)


func _ensure_nodes() -> void:
	if _camera_rig == null:
		_camera_rig = LOCAL_PLANE_CAMERA_RIG_SCENE.instantiate()
		_owner.add_child(_camera_rig)

	if _hud == null:
		_hud = PLANE_TELEMETRY_HUD_SCENE.instantiate()
		_owner.add_child(_hud)

	if _targeting_hud == null:
		_targeting_hud = PLANE_TARGETING_HUD_SCENE.instantiate()
		_owner.add_child(_targeting_hud)
