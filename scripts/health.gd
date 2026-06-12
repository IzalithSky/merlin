class_name Health
extends Node

@export var max_hp: float = 100.0

signal damaged(amount: float, current_hp: float)
signal shot_down()

var current_hp: float = 0.0
var _dead: bool = false


func _ready() -> void:
	current_hp = max_hp


func take_damage(amount: float) -> void:
	if _dead:
		return
	current_hp = clampf(current_hp - amount, 0.0, max_hp)
	damaged.emit(amount, current_hp)
	if current_hp <= 0.0:
		_dead = true
		shot_down.emit()


func apply_current_hp_from_network(value: float) -> void:
	var clamped_value := clampf(value, 0.0, max_hp)
	var previous_hp := current_hp
	current_hp = clamped_value
	if current_hp > 0.0:
		_dead = false
	if current_hp < previous_hp:
		damaged.emit(previous_hp - current_hp, current_hp)


func apply_shot_down_from_network() -> void:
	current_hp = 0.0
	if _dead:
		return
	_dead = true
	shot_down.emit()
