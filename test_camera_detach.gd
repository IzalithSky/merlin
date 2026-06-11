extends SceneTree

# Narrow harness: verifies camera-rig detach behavior after shot-down.
# Run: godot --headless --path /ssd2/projects/godot/merlin --script test_camera_detach.gd

const CameraRigScene := preload("res://scenes/local_plane_camera_rig.tscn")

var _pass_count := 0
var _fail_count := 0
var _frame := 0


func _process(_delta: float) -> bool:
	_frame += 1
	# Wait one frame so all @onready vars are populated.
	if _frame < 2:
		return false
	_run_tests()
	print("[RESULT] pass=%d fail=%d" % [_pass_count, _fail_count])
	quit(_fail_count)
	return false


func _run_tests() -> void:
	_test_detach_sets_is_detached()
	_test_detach_levels_basis()
	_test_detach_preserves_forward()
	_test_mouse_input_guard_passes_when_detached()
	_test_set_target_clears_detached()
	_test_fpv_hides_mesh()
	_test_fpv_camera_at_origin()
	_test_fpv_restore_on_set_target()
	_test_fpv_restore_on_detach()


# _detach_from_target must set _is_detached = true.
func _test_detach_sets_is_detached() -> void:
	var rig: Node = _make_rig()
	var plane: Node3D = _make_plane_node(Vector3(0, 100, 0), Vector3(0.0, 0.0, 0.0))
	rig.call("set_target", plane)
	rig.call("_detach_from_target")
	var is_detached: bool = rig.get("_is_detached")
	_assert(is_detached, "_is_detached should be true after _detach_from_target")
	rig.queue_free()
	plane.queue_free()


# After detach the rig basis should be identity (global upright).
func _test_detach_levels_basis() -> void:
	var rig: Node = _make_rig()
	var plane: Node3D = _make_plane_node(Vector3(0, 100, 0), Vector3(0.5, 0.3, 0.1))
	rig.call("set_target", plane)
	rig.call("_detach_from_target")
	var rig3d: Node3D = rig as Node3D
	var b: Basis = rig3d.global_transform.basis
	var ok: bool = b.is_equal_approx(Basis.IDENTITY)
	_assert(ok, "basis should be identity after detach, got: %s" % str(b))
	rig.queue_free()
	plane.queue_free()


# After detach the camera should keep approximately the same world-forward.
func _test_detach_preserves_forward() -> void:
	var rig: Node = _make_rig()
	var plane: Node3D = _make_plane_node(Vector3(0, 100, 0), Vector3(0.0, 0.0, 0.0))
	rig.call("set_target", plane)
	rig.set("_camera_yaw", deg_to_rad(45.0))
	rig.set("_camera_pitch", deg_to_rad(20.0))
	rig.call("_apply_camera_look")
	var pitch_pivot: Node3D = rig.get_node("%CameraPitchPivot") as Node3D
	var before_fwd: Vector3 = -pitch_pivot.global_transform.basis.z
	rig.call("_detach_from_target")
	var after_fwd: Vector3 = -pitch_pivot.global_transform.basis.z
	var dot: float = before_fwd.dot(after_fwd)
	_assert(dot > 0.999, "forward direction should be preserved after detach, dot=%.4f" % dot)
	rig.queue_free()
	plane.queue_free()


# The input guard (_target == null and not _is_detached) must be false when detached.
func _test_mouse_input_guard_passes_when_detached() -> void:
	var rig: Node = _make_rig()
	var plane: Node3D = _make_plane_node(Vector3(0, 100, 0), Vector3(0.0, 0.0, 0.0))
	rig.call("set_target", plane)
	rig.call("_detach_from_target")
	var target = rig.get("_target")
	var is_detached: bool = rig.get("_is_detached")
	var guard_blocks: bool = (target == null and not is_detached)
	_assert(not guard_blocks, "input guard should not block when _is_detached=true")
	rig.queue_free()
	plane.queue_free()


# set_target() should clear _is_detached.
func _test_set_target_clears_detached() -> void:
	var rig: Node = _make_rig()
	var plane: Node3D = _make_plane_node(Vector3(0, 100, 0), Vector3(0.0, 0.0, 0.0))
	rig.call("set_target", plane)
	rig.call("_detach_from_target")
	rig.call("set_target", plane)
	var detached_after: bool = rig.get("_is_detached")
	_assert(not detached_after, "_is_detached should clear when set_target() called again")
	rig.queue_free()
	plane.queue_free()


# FPV mode should hide BodyMesh on the target plane.
func _test_fpv_hides_mesh() -> void:
	var rig: Node = _make_rig()
	var plane: Node3D = _make_plane_node_with_mesh(Vector3(0, 100, 0))
	rig.call("set_target", plane)
	var mesh: Node3D = plane.get_node("BodyMesh") as Node3D
	_assert(mesh.visible, "mesh should be visible in third-person")
	rig.call("_set_first_person", true)
	_assert(not mesh.visible, "mesh should be hidden in first-person")
	rig.call("_set_first_person", false)
	_assert(mesh.visible, "mesh should be visible again after returning to third-person")
	rig.queue_free()
	plane.queue_free()


# FPV camera transform should be at identity (no arm offset).
func _test_fpv_camera_at_origin() -> void:
	var rig: Node = _make_rig()
	var plane: Node3D = _make_plane_node(Vector3(0, 100, 0), Vector3(0.0, 0.0, 0.0))
	rig.call("set_target", plane)
	var camera: Camera3D = rig.call("get_camera") as Camera3D
	var third_person_z: float = camera.transform.origin.z
	_assert(abs(third_person_z) > 1.0, "third-person camera should have non-zero Z offset (arm)")
	rig.call("_set_first_person", true)
	var fpv_origin: Vector3 = camera.transform.origin
	_assert(fpv_origin.is_zero_approx(), "FPV camera should be at local origin (no arm)")
	rig.call("_set_first_person", false)
	var restored_z: float = camera.transform.origin.z
	_assert(absf(restored_z - third_person_z) < 0.001, "camera arm should be restored after leaving FPV")
	rig.queue_free()
	plane.queue_free()


# set_target() should exit FPV and restore mesh on the old target.
func _test_fpv_restore_on_set_target() -> void:
	var rig: Node = _make_rig()
	var plane: Node3D = _make_plane_node_with_mesh(Vector3(0, 100, 0))
	var plane2: Node3D = _make_plane_node_with_mesh(Vector3(0, 200, 0))
	rig.call("set_target", plane)
	rig.call("_set_first_person", true)
	_assert(not (plane.get_node("BodyMesh") as Node3D).visible, "mesh hidden in FPV")
	rig.call("set_target", plane2)
	_assert((plane.get_node("BodyMesh") as Node3D).visible, "old target mesh restored on retarget")
	var fp_after: bool = rig.get("_first_person")
	_assert(not fp_after, "FPV should be off after set_target")
	rig.queue_free()
	plane.queue_free()
	plane2.queue_free()


# _detach_from_target() should exit FPV and restore mesh.
func _test_fpv_restore_on_detach() -> void:
	var rig: Node = _make_rig()
	var plane: Node3D = _make_plane_node_with_mesh(Vector3(0, 100, 0))
	rig.call("set_target", plane)
	rig.call("_set_first_person", true)
	_assert(not (plane.get_node("BodyMesh") as Node3D).visible, "mesh hidden in FPV before detach")
	rig.call("_detach_from_target")
	_assert((plane.get_node("BodyMesh") as Node3D).visible, "mesh restored after detach")
	var fp_after: bool = rig.get("_first_person")
	_assert(not fp_after, "FPV should be off after detach")
	rig.queue_free()
	plane.queue_free()


# -----------------------------------------------------------------------

func _make_rig() -> Node:
	var rig: Node = CameraRigScene.instantiate()
	get_root().add_child(rig)
	return rig


func _make_plane_node(pos: Vector3, euler_rad: Vector3) -> Node3D:
	var n := Node3D.new()
	get_root().add_child(n)
	n.global_position = pos
	n.global_transform.basis = Basis.from_euler(euler_rad).orthonormalized()
	return n


func _make_plane_node_with_mesh(pos: Vector3) -> Node3D:
	var n: Node3D = _make_plane_node(pos, Vector3.ZERO)
	var mesh := MeshInstance3D.new()
	mesh.name = "BodyMesh"
	n.add_child(mesh)
	return n


func _assert(condition: bool, msg: String) -> void:
	if condition:
		_pass_count += 1
		print("[PASS] %s" % msg)
	else:
		_fail_count += 1
		print("[FAIL] %s" % msg)
