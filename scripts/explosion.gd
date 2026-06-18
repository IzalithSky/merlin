extends Node3D

@onready var _sparks: GPUParticles3D = $Sparks
@onready var _smoke: GPUParticles3D = $Smoke
@onready var _fire: GPUParticles3D = $Fire
@onready var _sound: AudioStreamPlayer3D = $ExplosionSound


func _ready() -> void:
	_sparks.emitting = true
	_smoke.emitting = true
	_fire.emitting = true

	_sound.pitch_scale = randf_range(0.8, 1.2)
	_sound.play()

	await get_tree().create_timer(6.0).timeout
	queue_free()
