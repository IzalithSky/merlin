extends Node3D

const ALIGNMENT_MIN_DOT := 0.98
const POINT_COUNT_MIN := 2


func _ready() -> void:
	await get_tree().create_timer(0.1).timeout

	var characters := $World.find_child("characters", true, false)
	var plane := null if characters == null else characters.get_node_or_null("PlayerCharacter_1") as Node3D
	_assert(plane != null, "missing plane")

	var autocannon := plane.get_node_or_null("Autocannon") as Node
	_assert(autocannon != null, "missing autocannon")

	autocannon.call("try_fire")

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.05).timeout

	var bullets := get_tree().get_nodes_in_group("bullet")
	_assert(bullets.size() == 1, "expected one live bullet, got %d" % bullets.size())

	var bullet := bullets[0] as RigidBody3D
	_assert(bullet != null, "missing bullet body")
	_assert(bullet.linear_velocity.length_squared() > 0.000001, "bullet velocity is zero")

	var velocity_dir := bullet.linear_velocity.normalized()
	var root_forward := -bullet.global_transform.basis.z.normalized()
	_assert(root_forward.dot(velocity_dir) >= ALIGNMENT_MIN_DOT, "bullet root not aligned to velocity")

	var body_mesh := bullet.get_node_or_null("BodyMesh") as Node3D
	_assert(body_mesh != null, "missing bullet body mesh")
	var mesh_forward := body_mesh.global_transform.basis.y.normalized()
	_assert(mesh_forward.dot(velocity_dir) >= ALIGNMENT_MIN_DOT, "bullet mesh not aligned to velocity")

	var trail := bullet.get("_trail") as Node
	_assert(trail != null and is_instance_valid(trail), "missing bullet trail")
	var trail_points := trail.get("_points") as Array
	_assert(trail_points.size() >= POINT_COUNT_MIN, "bullet trail did not accumulate visible points")

	print("autocannon_smoke_ok bullet_count=%d trail_points=%d" % [bullets.size(), trail_points.size()])
	get_tree().quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	get_tree().quit(1)
