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
