extends Node3D

const SAMPLE_INTERVAL := 0.5
const TOTAL_DURATION := 8.0

var _elapsed: float = 0.0
var _sample_accum: float = 0.0
var _spawn_count: int = 0
var _bullet_next_id: int = 1
var _bullet_ids: Dictionary = {}
var _bullet_spawn_times: Dictionary = {}
var _bullet_lifetimes: Array[float] = []
var _active_bullets: Dictionary = {}
var _bullet_hit_flags: Dictionary = {}


func _ready() -> void:
	await get_tree().create_timer(0.1).timeout


func _process(delta: float) -> void:
	_elapsed += delta
	_sample_accum += delta
	_poll_projectiles()

	if _sample_accum >= SAMPLE_INTERVAL:
		_sample_accum = 0.0
		_emit_sample()

	if _elapsed >= TOTAL_DURATION:
		_finish()


func _emit_sample() -> void:
	var chase := $Chase
	var bot := chase.get("_bot") as PlaneCharacter
	var dummy := chase.get_node_or_null("DummyTarget") as Node3D
	if bot == null or dummy == null:
		print("probe missing bot_or_dummy")
		return

	var pilot := bot.get_node_or_null("PlaneBotPilot")
	var autocannon := bot.get_node_or_null("Autocannon")
	if pilot == null or autocannon == null:
		print("probe missing pilot_or_autocannon")
		return

	var to_target := dummy.global_position - bot.global_position
	var distance := to_target.length()
	var forward_axis := -bot.global_transform.basis.z.normalized()
	var direction_to_target := to_target.normalized() if distance > 0.001 else Vector3.ZERO
	var angle_deg := 0.0
	if distance > 0.001:
		angle_deg = rad_to_deg(acos(clampf(forward_axis.dot(direction_to_target), -1.0, 1.0)))

	var should_fire := bool(pilot.call("_should_fire_autocannon", dummy))
	var bullets := get_tree().get_nodes_in_group("bullet").size()
	var wrapper_projectiles := get_node_or_null("projectiles")
	var chase_projectiles := chase.get_node_or_null("projectiles")
	print(
		"probe",
		" t=%.1f" % _elapsed,
		" bullets=%d" % bullets,
		" spawned=%d" % _spawn_count,
		" wrapper_proj=%d" % (wrapper_projectiles.get_child_count() if wrapper_projectiles != null else -1),
		" chase_proj=%d" % (chase_projectiles.get_child_count() if chase_projectiles != null else -1),
		" should_fire=%s" % str(should_fire),
		" range=%.1f" % distance,
		" max_range=%.1f" % float(pilot.get("autocannon_fire_max_range")),
		" angle=%.1f" % angle_deg,
		" cone=%.1f" % float(autocannon.get("lead_cone_half_angle_deg"))
	)


func _finish() -> void:
	var avg_lifetime := 0.0
	for lifetime in _bullet_lifetimes:
		avg_lifetime += lifetime
	if not _bullet_lifetimes.is_empty():
		avg_lifetime /= float(_bullet_lifetimes.size())
	print(
		"probe done bullets=%d spawned=%d despawned=%d avg_lifetime=%.3f lifetimes=%s"
		% [
			get_tree().get_nodes_in_group("bullet").size(),
			_spawn_count,
			_bullet_lifetimes.size(),
			avg_lifetime,
			str(_bullet_lifetimes)
		]
	)
	get_tree().quit(0)


func _poll_projectiles() -> void:
	var container := get_node_or_null("projectiles")
	if container == null:
		return

	var seen: Dictionary = {}
	for child in container.get_children():
		if not child.is_in_group("bullet"):
			continue
		var instance_id := child.get_instance_id()
		seen[instance_id] = child
		if _active_bullets.has(instance_id):
			continue
		_register_bullet(child)

	var removed_ids: Array[int] = []
	for instance_id_variant in _active_bullets.keys():
		var instance_id := int(instance_id_variant)
		if not seen.has(instance_id):
			removed_ids.append(instance_id)

	for instance_id in removed_ids:
		_finalize_bullet(instance_id)


func _register_bullet(node: Node) -> void:
	var bullet_id := _bullet_next_id
	_bullet_next_id += 1
	var instance_id := node.get_instance_id()
	_active_bullets[instance_id] = bullet_id
	_bullet_spawn_times[bullet_id] = _elapsed
	_bullet_hit_flags[bullet_id] = false
	_spawn_count += 1
	if node.has_signal("died"):
		node.died.connect(_on_bullet_died.bind(bullet_id), CONNECT_ONE_SHOT)
	print("bullet_spawn id=%d t=%.3f instance=%d" % [bullet_id, _elapsed, instance_id])


func _finalize_bullet(instance_id: int) -> void:
	var bullet_id_variant: Variant = _active_bullets.get(instance_id)
	if bullet_id_variant == null:
		return
	_active_bullets.erase(instance_id)
	var bullet_id := int(bullet_id_variant)
	var spawn_time_variant: Variant = _bullet_spawn_times.get(bullet_id)
	if spawn_time_variant == null:
		return
	_bullet_spawn_times.erase(bullet_id)
	var spawn_time := float(spawn_time_variant)
	var lifetime := _elapsed - spawn_time
	_bullet_lifetimes.append(lifetime)
	print(
		"bullet_despawn id=%d t=%.3f lifetime=%.3f hit=%s instance=%d"
		% [bullet_id, _elapsed, lifetime, str(bool(_bullet_hit_flags.get(bullet_id, false))), instance_id]
	)
	_bullet_hit_flags.erase(bullet_id)


func _on_bullet_died(hit: bool, _position: Vector3, bullet_id: int) -> void:
	_bullet_hit_flags[bullet_id] = hit
