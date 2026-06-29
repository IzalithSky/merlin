class_name SinglePlayerMatchHud
extends CanvasLayer

@onready var _score_value: Label = %ScoreValue
@onready var _time_value: Label = %TimeValue

var _mission_controller: Node = null


func _ready() -> void:
	_reset_labels()


func set_mission_controller(mission_controller: Node = null) -> void:
	_mission_controller = mission_controller
	if _mission_controller == null:
		_reset_labels()


func _process(_delta: float) -> void:
	if _mission_controller == null or not is_instance_valid(_mission_controller) or not _mission_controller.is_single_player_session():
		visible = false
		return

	visible = true
	var score: int = _mission_controller.get_single_player_score()
	var victory_score: int = _mission_controller.get_single_player_victory_score()
	if victory_score > 0:
		_score_value.text = "%d / %d" % [score, victory_score]
	else:
		_score_value.text = "%d" % score

	if _mission_controller.has_single_player_time_limit():
		_time_value.text = _format_match_time(_mission_controller.get_single_player_time_remaining_sec())
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
