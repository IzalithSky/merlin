class_name SinglePlayerMatchHud
extends CanvasLayer

@onready var _score_value: Label = %ScoreValue
@onready var _time_value: Label = %TimeValue

var _world_spawner: WorldCharacterSpawner


func _ready() -> void:
	_reset_labels()


func set_world_spawner(world_spawner: WorldCharacterSpawner = null) -> void:
	_world_spawner = world_spawner
	if _world_spawner == null:
		_reset_labels()


func _process(_delta: float) -> void:
	if _world_spawner == null or not is_instance_valid(_world_spawner) or not _world_spawner.is_single_player_session():
		visible = false
		return

	visible = true
	var score: int = _world_spawner.get_single_player_score()
	var victory_score: int = _world_spawner.get_single_player_victory_score()
	if victory_score > 0:
		_score_value.text = "%d / %d" % [score, victory_score]
	else:
		_score_value.text = "%d" % score

	if _world_spawner.has_single_player_time_limit():
		_time_value.text = _format_match_time(_world_spawner.get_single_player_time_remaining_sec())
	else:
		_time_value.text = "∞"


func _reset_labels() -> void:
	visible = false
	_score_value.text = "--"
	_time_value.text = "--"


func _format_match_time(seconds_remaining: float) -> String:
	var total_seconds := maxi(int(ceil(seconds_remaining)), 0)
	var minutes := int(total_seconds / 60.0)
	var seconds := total_seconds % 60
	return "%d:%02d" % [minutes, seconds]
