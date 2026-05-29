# Plane Physics Spec (Current Implementation)

## Scope
This document specifies the current flight/physics behavior implemented by:

- `res://scripts/plane_character_controller.gd`
- `res://scenes/plane_character.tscn`

It describes what the system does now, not an idealized aerodynamics model.

## Physical Setup

From `plane_character.tscn`:

- Body type: `RigidBody3D`
- Mass: `500 kg`
- Collider: `BoxShape3D.size = Vector3(10, 1, 10)` (meters)
- Damping:
  - `linear_damp = 0.05`
  - `angular_damp = 0.8`

Coordinate conventions in script:

- Forward axis: `-transform.basis.z`
- Up axis: `transform.basis.y`
- Right axis: `transform.basis.x`

## Authority Model

- Local player plane (`is_local_player = true`) runs full physics/control in `_physics_process`.
- Remote planes do not simulate local control physics; they are snap-updated by `apply_remote_state(...)` (position + Euler rotation), with linear/angular velocity zeroed.

## Per-Frame Execution Order

For local player only, each physics tick:

1. Collect and smooth inputs (`_collect_inputs`)
2. Compute derived state (`compute_aoa`, `update_g_force`)
3. Apply thrust (`apply_thrust`)
4. Apply control torques via offset force-pairs (`apply_plane_torque`)
5. Apply lift (`apply_lift`)
6. Apply drag (`apply_air_drag`)
7. Apply velocity-alignment torque (`apply_directional_alignment`)
8. Emit network state at `network_sync_interval`

## Input Model

### Rotational Inputs

- Roll:
  - `D` decreases roll input
  - `A` increases roll input
  - no key: decays toward 0
- Pitch:
  - `W` increases pitch input
  - `S` decreases pitch input
  - no key: decays toward 0
- Yaw:
  - `Q` increases yaw input
  - `E` decreases yaw input
  - no key: decays toward 0

Smoothing:

- Ramp rate: `rot_rate` (default `2.4`)
- Return-to-zero decay: `rot_decay` (default `3.0`)
- Clamped to `[-1, 1]`

### Throttle Input

- `Space`: increase throttle
- `Shift`: decrease throttle
- No auto-decay to idle; throttle holds last value.

Throttle signal:

- `throttle_input` is clamped `[-1, 1]`
- Physical throttle fraction is `(throttle_input + 1) * 0.5`
- HUD throttle percent is `((throttle_input + 1) * 0.5) * 100`

## Derived State

### AoA

When speed is above epsilon:

- `aoa_deg = rad_to_deg(-atan2(v_dir·up, v_dir·forward))`
- `horizontal_aoa_deg = rad_to_deg(atan2(v_dir·right, v_dir·forward))`

### Smoothed G-force

- Instantaneous: `|((v - v_prev)/dt - gravity)| / 9.80665`
- Moving average over `G_BUFFER_SIZE = 10` samples.

## Force and Torque Model

## 1) Thrust

Applied each tick:

- `F_thrust = forward * throttle * max_thrust`
- Default `max_thrust = 8000 N`

No thrust if throttle fraction is `<= 0`.

## 2) Pilot Control Torque (Pitch/Yaw/Roll)

### Speed scaling

- Forward speed: `v_fwd = linear_velocity · forward`
- Dynamic term: `q = 0.5 * v_fwd^2`
- `t = max(0, v_fwd) / control_effectiveness_speed`
- If `aoa_limiter`:
  - `speed_factor = 1 / (1 + t^(2*speed_assist))`
- Else:
  - `speed_factor = 1 / (1 + t^1.6)`

### Commanded torques

- `control_torque = base_control_torque + q * dynamic_torque_scale`
- `pitch_torque = (-pitch_input * speed_factor) * control_torque * max_pitch`
- `yaw_torque = (yaw_input * speed_factor) * control_torque * max_yaw`
- `roll_torque = (roll_input * speed_factor) * control_torque * max_roll`

Defaults:

- `base_control_torque = 4000`
- `dynamic_torque_scale = 3.0`
- `max_pitch = 0.8`, `max_yaw = 0.1`, `max_roll = 1.0`

### Torque application method (offset force pairs)

Pilot torques are not applied at COM via `apply_torque`.  
They are converted into a force couple at `+/-offset`:

- Roll torque applied at side edges (`X` lever arm)
- Pitch+yaw torque applied at rear (`Z` lever arm)

Force-pair solver used:

- `tau = 2 * (r x F)`
- `F = (tau x r) / (2 * |r|^2)`

Then applied as:

- `apply_force(+F, +r)`
- `apply_force(-F, -r)`

### Lever arm derivation from rigidbody size

Lever arms are derived from collision half-extents:

- `roll_offset = max(half_extents.x, 0.05)`
- `tail_offset = max(half_extents.z, 0.05)`

So actuator leverage tracks body size automatically.

## 3) Lift

Only when speed > epsilon and not stalled.

- `dynamic_pressure = 0.5 * |v|^2`
- `vertical_cl = lift_coefficient + 2π * deg_to_rad(aoa_deg)`
- `lateral_cl = -2π * deg_to_rad(horizontal_aoa_deg)`
- Stall gate:
  - `abs(aoa_deg) < stall_aoa_deg`
  - `abs(horizontal_aoa_deg) < stall_aoa_deg`

Applied forces:

- Vertical: `up * dynamic_pressure * vertical_cl`
- Lateral: `right * dynamic_pressure * lateral_cl`

Defaults:

- `lift_coefficient = 0.0`
- `stall_aoa_deg = 30.0`

## 4) Drag

Quadratic drag per local axis:

- Forward drag coefficient: `drag_forward = 0.005`
- Up drag coefficient: `drag_up = 0.05`
- Side drag coefficient: `drag_side = 0.025`

Form:

- `F_axis = -axis * (v·axis) * abs(v·axis) * coeff`

Summed and applied centrally.

## 5) Directional Alignment Torque

Separate from pilot control torques; still applied directly with `apply_torque`.

- Axis: `forward x velocity_direction`
- Angle: `angle(forward, velocity_direction)`
- Torque magnitude: `angle * alignment_strength * |v|`
- Capped by `alignment_max_torque`

Defaults:

- `alignment_strength = 5.0`
- `alignment_max_torque = 1000.0`

This is the “nose tends to align with velocity” behavior.

## Control Geometry Cache

Collision-size-derived lever arms are cached and refreshed only when needed.

Cache fields:

- `_cached_control_half_extents`
- `_control_half_extents_dirty`

Invalidation triggers:

- `CollisionShape3D` child enters/exits tree
- Observed shape resource emits `changed`

Refresh path:

1. Ensure shape-resource watches are connected
2. Recompute combined local AABB half-extents from all active `CollisionShape3D`s

Supported shape types for extents:

- `BoxShape3D`, `SphereShape3D`, `CapsuleShape3D`, `CylinderShape3D`
- `ConvexPolygonShape3D`, `ConcavePolygonShape3D`

Fallback if no valid bounds:

- `Vector3(1, 1, 1)`

## Network Coupling

- Local authoritative state is emitted every `network_sync_interval` (default `0.033 s`).
- Emitted state: `position`, `yaw`, `pitch`, `roll`.
- Remote application is teleport/snap style (`apply_remote_state`), not force-based reconciliation.

## HUD Interface

The physics controller exposes getters used by HUD:

- `get_throttle_percent()`
- `get_aoa_deg()`
- `get_pitch_input()`
- `get_yaw_input()`
- `get_roll_input()`
- `get_throttle_input()`

