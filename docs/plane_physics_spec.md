# Plane Physics Spec (Current Implementation)

## Scope
This document describes the current flight model implemented by:

- `res://scripts/plane_character_controller.gd`
- `res://scenes/plane_character.tscn`
- `res://scripts/plane_aero_tables_store.gd` (table persistence)

It documents actual runtime behavior, not an idealized aircraft model.

## Physical Setup
From `plane_character.tscn`:

- Body type: `RigidBody3D`
- Mass: `500 kg`
- Collision shape: `BoxShape3D.size = Vector3(10, 1, 10)` (Godot units, typically meters)
- `linear_damp_mode = REPLACE`
- `linear_damp = 0.0`
- `angular_damp = 0.8`

Axis conventions:

- Forward: `-transform.basis.z`
- Up: `transform.basis.y`
- Right: `transform.basis.x`

Gravity is not custom-applied by script; engine `RigidBody3D` gravity is used.

## Engine-Level Speed Limit (Observed Finding)
Current project physics backend is Jolt (`project.godot`: `physics/3d/physics_engine="Jolt Physics"`).

Jolt applies a global linear velocity clamp:

- `physics/jolt_physics_3d/limits/max_linear_velocity = 500.0`

This means `|linear_velocity|` cannot exceed `500.0 m/s` regardless of positive net force.

Practical consequence:

- Plane can show positive forward net force (`Net . vhat > 0`) while speed stays at `500.0 m/s`.
- In this state, the limiter is engine-side velocity clamping, not aerodynamic equilibrium.

## Simulation Modes and Authority
`plane_character_controller.gd` can run in three modes:

1. Local player simulated:
- `is_local_player = true`
- Reads keyboard input (`_collect_inputs`) and simulates full forces/torques.

2. Bot-simulated authority:
- `is_bot_controlled = true`
- Reads bot target inputs (`_apply_bot_inputs`) and simulates full forces/torques.

3. Remote replica:
- Neither local player nor bot-controlled.
- No local force simulation in `_physics_process`.
- Transform is snap-updated through `apply_remote_state(position, yaw, pitch, roll)`.

`freeze` is toggled from `_apply_local_player_mode()`:

- Simulated locally: unfreezes body and disables sleeping.
- Non-simulated replicas: frozen.

## Per-Tick Update Order
When the plane is locally simulated (`is_local_player` or `is_bot_controlled`), physics tick flow is:

1. Input step:
- Player: `_collect_inputs(delta)`
- Bot: `_apply_bot_inputs(delta)`

2. Derived state:
- `compute_aoa()`
- `update_g_force(delta)`

3. Forces and torques:
- `apply_thrust()`
- `apply_plane_torque()`
- `apply_aerodynamic_forces()`
- `apply_directional_alignment()`

4. Network output:
- Emit `local_state_changed` every `network_sync_interval` seconds.

## Input Model
### Player Input
Roll:

- `D` decreases roll input
- `A` increases roll input
- Else decays toward zero

Pitch raw input:

- `W` increases `pitch_input`
- `S` decreases `pitch_input`

Pitch command sign is inverted in torque conversion (`p_in = -pitch_input`), which matches the current tuned behavior where `W` commands nose-down and `S` commands nose-up.

Yaw:

- `Q` increases yaw input
- `E` decreases yaw input

Throttle:

- `Space` increases `throttle_input`
- `Shift` decreases `throttle_input`
- No auto-decay; throttle holds last value

Smoothing/limits:

- Rotation input ramp: `rot_rate * delta`
- Rotation return-to-center: `rot_decay * delta`
- Throttle ramp: `thr_rate * delta`
- All command channels clamp to `[-1, 1]`

### Bot Input
Bot script calls:

- `set_bot_control_inputs(roll, pitch, yaw, throttle)`

The controller does not apply values instantly. It moves current channels toward bot targets with the same rate limits (`rot_rate`, `thr_rate`) via `_apply_bot_inputs(delta)`.

## Derived State
### Air-Relative Velocity
Air-relative velocity is:

- `v_air = linear_velocity - ambient_wind_velocity_world`

All aerodynamic calculations use `v_air`.

### Angle of Attack and Sideslip
When `|v_air|^2 >= MIN_AERODYNAMIC_SPEED_SQUARED`:

- Convert `v_air` to local space.
- `aoa_deg = rad_to_deg(-atan2(flow_up, flow_forward))`
- `sideslip_deg = rad_to_deg(atan2(flow_right, forward_plane_speed))`

When speed is below threshold:

- `aoa_deg = 0`
- `sideslip_deg = 0`

### Smoothed G
Instantaneous g:

- `|((v - v_prev) / dt - gravity)| / 9.80665`

`smoothed_g` is average of the last `G_BUFFER_SIZE` samples.

## Force and Torque Model
### Thrust
Throttle fraction:

- `throttle = (throttle_input + 1) * 0.5`

If `throttle > 0`:

- `F_thrust = forward * throttle * max_thrust`

Defaults:

- `max_thrust = 8000 N`

### Control Torque (Roll/Pitch/Yaw)
Forward speed:

- `v_fwd = dot(v_air, forward)`

Speed attenuation:

- `t = max(0, v_fwd) / control_effectiveness_speed`
- If `aoa_limiter` is `true`: `speed_factor = 1 / (1 + t^(2 * speed_assist))`
- Else: `speed_factor = 1 / (1 + t^(2 * 0.8))`

Command shaping:

- `p_in = -pitch_input * speed_factor`
- `y_in = yaw_input * speed_factor`
- `r_in = roll_input * speed_factor`

Torque magnitude base:

- `control_torque = base_control_torque + 0.5 * v_fwd^2 * dynamic_torque_scale`

Axis torques:

- `pitch_torque = p_in * control_torque * max_pitch`
- `yaw_torque = y_in * control_torque * max_yaw`
- `roll_torque = r_in * control_torque * max_roll`

### Torque Application Method
Torques are applied as force couples, not direct COM torque for control surfaces:

- Roll couple lever arm on local X (`roll_offset`)
- Pitch/yaw couple lever arm on local Z (`tail_offset`)

Force-pair solver:

- `tau = 2 * (r x F)`
- `F = (tau x r) / (2 * |r|^2)`

Applied as `+F@+r` and `-F@-r`.

### Lever Arm Size Derivation
`roll_offset` and `tail_offset` are derived from collision bounds:

- `roll_offset = max(half_extents.x, 0.05)`
- `tail_offset = max(half_extents.z, 0.05)`

Half extents are cached and invalidated when collision shape nodes/resources change.

## Aerodynamic Force Model
### Dynamic Pressure

- `q = 0.5 * air_density * |v_air|^2`

### Coefficients
Coefficients are sampled from exported tables:

- Lift coefficient from `lift_coefficient_table` using `aoa_deg`
- Drag coefficient from `drag_coefficient_table` using `aoa_deg` (clamped to `>= 0`)
- Side-force coefficient from `side_force_coefficient_table` using `sideslip_deg`

Table sampling behavior (`_sample_aero_table`):

- Sort/dedup handled separately by `_normalize_table`
- Linear interpolation between bracketing points
- Below first point: return first point value
- Above last point: return last point value

### Force Directions
With `airflow_direction = normalize(v_air)`:

- Drag direction: `-airflow_direction`
- Lift axis: `right_axis.cross(airflow_direction)` (fallback to body up if degenerate)
- Side axis: `airflow_direction.cross(lift_axis)` (fallback to body right if degenerate)

Force magnitudes:

- `F_drag = q * reference_area * CD`
- `F_lift = q * reference_area * CL`
- `F_side = q * reference_area * CY`

Total aerodynamic force:

- `F_aero = drag_dir * F_drag + lift_axis * F_lift + side_axis * F_side`

Current default `side_force_coefficient_table` is flat zero, so side force is effectively disabled unless tuned.

### Directional Alignment Torque
Additional alignment torque nudges nose toward flight path:

- axis = `forward x velocity_direction`
- angle = `angle(forward, velocity_direction)`
- torque magnitude scales with `angle * alignment_strength * |v_air|`
- capped by `alignment_max_torque`

This is the dart-like nose alignment behavior.

## Networking Behavior
### Outgoing State
Locally simulated planes emit:

- `peer_id`
- `global_position`
- `yaw`, `pitch`, `roll` (from Euler basis)

at `network_sync_interval` (default `0.033`).

### Incoming State
`apply_remote_state(...)` on non-local planes:

- snaps position and Euler rotation
- zeroes linear and angular velocity

So remote representation is transform-snapshot replication, not deterministic replay.

## Persistence of Aero Tables
On ready, controller loads persisted tables from:

- `user://plane_aero_tables.json`

Persistence currently includes:

- Lift table
- Drag table

Side-force table is not persisted by `plane_aero_tables_store.gd` in current implementation.

## HUD-Exposed Signals/Getters
HUD-facing getters:

- `get_throttle_percent()`
- `get_aoa_deg()`
- `get_sideslip_deg()`
- `get_pitch_input()`
- `get_yaw_input()`
- `get_roll_input()`
- `get_throttle_input()`
- `get_force_balance_snapshot()`:
  - `speed`
  - `thrust_along_velocity`
  - `drag_along_velocity`
  - `gravity_along_velocity`
  - `damping_along_velocity`
  - `net_along_velocity`

`*_along_velocity` values are dot products on `vhat` (velocity direction), so they represent accelerate/decelerate contribution along the current flight path.

## Current Simplifications
- No explicit stall model in force application.
- `lift_ok` is currently set `true` in `apply_aerodynamic_forces()` and not used as a real stall gate.
- No per-surface wing/tail model; forces are lumped at rigidbody center.
