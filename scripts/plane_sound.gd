class_name PlaneSound
extends Node3D

const _BASE_PITCH := 0.6

@onready var _engine: AudioStreamPlayer3D = $EngineSound


func _ready() -> void:
	var stream := _engine.stream.duplicate() as AudioStreamOggVorbis
	stream.loop = true
	_engine.stream = stream
	_engine.play()


func _process(_delta: float) -> void:
	var plane := get_parent()
	if plane == null or not is_instance_valid(plane):
		return
	var t := clampf(float(plane.get("throttle_percent")) / 100.0, 0.0, 1.0)
	_engine.pitch_scale = _BASE_PITCH * lerp(1.0, 1.5, t)
