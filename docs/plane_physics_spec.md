# Plane Physics Spec

## Scope
This document describes the current flight model implemented by:

- `res://scripts/plane_character_controller.gd`
- `res://scenes/plane_character.tscn`
- `res://scripts/plane_aero_tables_store.gd`

It documents actual runtime behavior, not an idealized aircraft model.

## Physical Setup
From `plane_character.tscn`:

- Body type: `RigidBody3D`
- Mass: `3000 kg`
- Collision shape: `BoxShape3D.size = Vector3(10, 1, 10)`
- Visual mesh: single orange `PrismMesh`, visually triangular from top view
- `continuous_cd = true`
- `linear_damp_mode = REPLACE`
- `linear_damp = 0.0`
- `angular_damp_mode = REPLACE`
- `angular_damp = 0.0`

Axis conventions:

- Forward: `-global_transform.basis.z`
- Right: `global_transform.basis.x`
- Up: `global_transform.basis.y`

Godot/Jolt owns rigid body integration and gravity. The script applies thrust, aerodynamic forces, extra drag, angular drag, control torque, and directional alignment torque.

## Engine-Level Speed Limit
The project uses Jolt:

- `physics/3d/physics_engine="Jolt Physics"`

Observed behavior: linear velocity is clamped around `500 m/s` by the physics backend/default project setting. This means the HUD can show positive `Net . vhat` while speed remains pinned at `500 m/s`. In that case the speed cap is engine-side velocity limiting, not aerodynamic equilibrium.

## Simulation Authority
`plane_character_controller.gd` runs in three authority modes.

Local player:

- `is_local_player = true`
- Reads keyboard input.
- Simulates full forces and torques locally.

Bot authority:

- `is_bot_controlled = true`
- Receives target inputs from `PlaneBotPilot`.
- Simulates full forces and torques locally.
- In multiplayer this is server-side only.

Remote replica:

- Neither local player nor bot-controlled.
- `_physics_process()` exits without applying forces.
- Body is frozen.
- `apply_remote_state()` snap-updates transform from network snapshots and clears local velocities.

## Per-Tick Flow
When locally simulated, `_physics_process(delta)` runs:

1. Reset force-debug frame.
2. Collect player input or smooth bot target inputs.
3. Update cached frame quantities:
   - body basis
   - local axes
   - air-relative velocity
   - airspeed and airspeed squared
   - airflow direction
   - dynamic pressure
4. Compute AoA and sideslip.
5. Apply thrust.
6. Apply control torque after pitch limiters.
7. Apply table-driven aerodynamic lift/drag/side force.
8. Apply extra linear drag and angular drag.
9. Apply directional alignment torque.
10. Emit network state on `network_sync_interval`.

## Input Model
Player controls:

- `W`: positive `pitch_input`, commands nose-down after sign inversion
- `S`: negative `pitch_input`, commands nose-up after sign inversion
- `A`: positive `roll_input`
- `D`: negative `roll_input`
- `Q`: positive `yaw_input`
- `E`: negative `yaw_input`
- `Space`: increases throttle
- `Shift`: decreases throttle
- `Ctrl`: temporarily disables sustain-turn pitch limiting only

Throttle does not decay. It holds the last value.

Input smoothing:

- Rotation channels move at `rot_rate * delta`
- Rotation channels decay toward zero at `rot_decay * delta`
- Throttle moves at `thr_rate * delta`
- All channels clamp to `[-1, 1]`

Spawn defaults:

- Pitch/yaw/roll input: `0`
- `throttle_input = 0`
- `throttle_percent = 50`

Bot controls:

- Bot calls `set_bot_control_inputs(roll, pitch, yaw, throttle)`.
- Plane controller smooths current input channels toward bot targets.
- Bot and player share the same downstream physics, torque, drag, and pitch limiter code.

## Air-Relative State
Air-relative velocity:

```text
v_air = linear_velocity - ambient_wind_velocity_world
```

Current wind defaults to zero.

Dynamic pressure:

```text
q = 0.5 * air_density * |v_air|^2
```

Default:

- `air_density = 1.225`
- `reference_area = 12.0`

AoA and sideslip are computed from `v_air` transformed into body-local space:

```text
flow_forward = -v_air_local.z
flow_up = v_air_local.y
flow_right = v_air_local.x
forward_plane_speed = sqrt(flow_forward^2 + flow_up^2)

aoa_deg = -atan2(flow_up, flow_forward) in degrees
sideslip_deg = atan2(flow_right, forward_plane_speed) in degrees
```

Below `MIN_AERODYNAMIC_SPEED_SQUARED`, AoA and sideslip are reset to zero.

## Thrust
Throttle fraction:

```text
throttle = clamp((throttle_input + 1) * 0.5, 0, 1)
```

Thrust force:

```text
F_thrust = forward_axis * throttle * max_thrust
```

Current default:

- `max_thrust = 14000 N`

Thrust is applied as a central force.

## Control Torque
Control authority is table-driven by total air-relative speed magnitude, not forward-axis speed:

```text
control_coefficient = sample(control_authority_coefficient_table, |v_air|)
control_torque = base_control_torque * max(control_coefficient, 0)
```

Current defaults:

- `base_control_torque = 40000`
- `max_pitch = 2.0`
- `max_yaw = 0.8`
- `max_roll = 2.5`

Axis commands:

```text
limited_pitch_input = max_lift_limiter_then_sustain_limiter(pitch_input)

p_in = -limited_pitch_input
y_in = yaw_input
r_in = roll_input

pitch_torque = p_in * control_torque * max_pitch
yaw_torque = y_in * control_torque * max_yaw
roll_torque = r_in * control_torque * max_roll
```

Torque application:

- Pitch/yaw torque is transformed from local `Vector3(pitch_torque, yaw_torque, 0)`.
- Roll torque is transformed from local `Vector3(0, 0, roll_torque)`.
- The sum is applied with `apply_torque()`.
- Control torques are direct center-of-mass torques now. There are no offset force couples.

## Pitch Limiters
Pitch limiters are input/authority limiters only. They do not change lift, drag, thrust, gravity, velocity, position, or AoA directly.

Both player and bot go through the same limiter path:

```text
_get_turn_limited_pitch_input()
  -> _get_max_lift_limited_pitch_input()
  -> _get_sustain_turn_limited_pitch_input()
```

### Max-Lift Turn Limiter
The max-lift limiter prevents pitch input from pushing AoA past the peak lift points in the lift table.

Limit extraction:

- Positive max-lift AoA: positive `x` value with highest `CL`.
- Negative max-lift AoA: negative `x` value with lowest `CL`.
- Defaults fall back around `+/-15 deg` if the table lacks one side.

Activation:

- `max_lift_turn_limiter_enabled = true`
- `_frame_air_speed >= max_lift_turn_limiter_min_airspeed`
- current default minimum airspeed: `5 m/s`

Behavior:

- If AoA is near/above positive max-lift AoA, nose-up pitch input is faded/blocked.
- Nose-down recovery remains allowed.
- If AoA is near/below negative max-lift AoA, nose-down pitch input is faded/blocked.
- Nose-up recovery remains allowed.

Fade:

- `max_lift_turn_limiter_fade_deg = 3.0`
- Within this band, authority scales from full to zero.

### Sustain-Turn Limiter
The sustain limiter further limits pitch input so the requested AoA should not require more drag force than current thrust plus gravity can support along the current flight path.

Activation:

- `sustain_turn_limiter_enabled = true`
- runtime sustain toggle is enabled
- local player is not holding `Ctrl`
- `_frame_air_speed >= max_lift_turn_limiter_min_airspeed`

Available forward force:

```text
available = dot(F_thrust, airflow_direction) + dot(F_gravity, airflow_direction)
```

Consequences:

- Descending flight: gravity can add available forward force.
- Climbing flight: gravity subtracts available forward force.

Target speed:

```text
target_speed = max(current_airspeed, sustain_turn_limiter_min_target_airspeed)
```

Current default:

- `sustain_turn_limiter_min_target_airspeed = 100 m/s`

Required force for candidate AoA:

```text
required = (
  q_target * reference_area * CD(candidate_aoa)
  + extra_linear_drag
  + extra_quadratic_drag
  + engine_damping_drag
) * sustain_turn_limiter_drag_margin
```

Current defaults:

- `sustain_turn_limiter_samples = 48`
- `sustain_turn_limiter_drag_margin = 1.05`
- `sustain_turn_limiter_fade_deg = 3.0`

The limiter samples candidate AoA values from `0` toward the max-lift bound and keeps the largest AoA whose `required <= available`.

The sustain scan is optimized so target-speed terms and non-AoA drag terms are computed once per scan. Only drag coefficient sampling changes per candidate AoA.

Bot-specific policy:

- Bot enables sustain limiting while forward speed is `<= speed_recovery_exit_speed`.
- Bot disables sustain limiting above `speed_recovery_exit_speed`, so only max-lift AoA limiting applies.
- Current bot recovery exit speed is `150 m/s`.

## Aerodynamic Forces
Aerodynamic coefficients are sampled from editable tables:

- `lift_coefficient_table` by `aoa_deg`
- `drag_coefficient_table` by `aoa_deg`, clamped to `>= 0`
- `side_force_coefficient_table` by `sideslip_deg`

Table sampling:

- Tables are sorted and duplicate `x` values are deduped.
- Values linearly interpolate between adjacent points.
- Values outside the table use flat edge extrapolation:
  - below first point: first value
  - above last point: last value

Force directions:

```text
drag_direction = -airflow_direction
lift_axis = right_axis.cross(airflow_direction)
side_axis = airflow_direction.cross(lift_axis)
```

Fallbacks:

- If lift axis degenerates, use body up.
- If side axis degenerates, use body right.

Magnitudes:

```text
F_drag = q * reference_area * CD
F_lift = q * reference_area * CL
F_side = q * reference_area * CY
```

Total:

```text
F_aero = drag_direction * F_drag
       + lift_axis * F_lift
       + side_axis * F_side
```

Current side-force table is flat zero by default, so lateral aerodynamic force is effectively disabled unless tuned.

Aerodynamic forces are applied as central force.

## Extra Drag
AoA-table drag is not the only drag source.

Extra linear drag:

```text
F_extra_drag = -airflow_direction * (
  extra_linear_drag_linear_coefficient * |v_air|
  + extra_linear_drag_quadratic_coefficient * |v_air|^2
)
```

Current defaults:

- `extra_linear_drag_linear_coefficient = 0.0`
- `extra_linear_drag_quadratic_coefficient = 0.12`

Extra angular drag:

1. Transform angular velocity into local body space.
2. For each local axis:

```text
torque = -sign(axis_rate) * (
  linear_coefficient * abs(axis_rate)
  + quadratic_coefficient * abs(axis_rate)^2
)
```

3. Transform local torque back to world space.
4. Apply with `apply_torque()`.

Current defaults:

- Linear angular coefficients: `Vector3(20000, 12000, 20000)`
- Quadratic angular coefficients: `Vector3(2500, 1200, 2500)`

The body also reports equivalent engine damping force for HUD/debug using `state.total_linear_damp`, but built-in linear/angular damping are currently zero in the plane scene.

## Directional Stability
Directional alignment is the dart-like behavior that turns the nose toward the air-relative movement direction.

```text
axis = forward_axis.cross(airflow_direction)
angle = forward_axis.angle_to(airflow_direction)
torque = normalize(axis) * angle * alignment_strength * |v_air|
```

Current defaults:

- `alignment_strength = 100`
- `alignment_max_torque = 10000`

If `alignment_max_torque > 0`, the torque is length-limited before applying.

## Debug Forces and HUD
Force debug renderer can show:

- thrust
- lift
- drag
- gravity
- damping / extra drag
- pitch/yaw torque
- roll torque
- alignment torque

Display options are persisted in:

- `user://display_settings.cfg`

Current toggles:

- `debug_force_arrows_enabled`
- `advanced_hud_enabled`

Advanced HUD includes AoA, input bars, and force balance rows.

`get_force_balance_snapshot()` reports:

- speed
- thrust along velocity direction
- drag along velocity direction
- gravity along velocity direction
- damping along velocity direction
- net force along velocity direction

These are projected on `vhat = normalize(linear_velocity)`, so they describe acceleration/deceleration along the current movement direction.

## Aero Table Persistence
Editable graph data is saved in:

- `user://plane_aero_tables.json`

Persisted tables:

- lift table
- drag table
- control authority table

Current save version:

- `2`

The side-force table is exported on the controller but is not currently persisted by `plane_aero_tables_store.gd`.

## Networking Behavior
Locally simulated planes emit:

- `peer_id`
- `global_position`
- yaw
- pitch
- roll

at `network_sync_interval`.

Default:

- `network_sync_interval = 0.033`

Remote planes:

- receive transform snapshots
- snap position/rotation
- zero local velocity and angular velocity

This is snapshot replication, not deterministic physics replay.

## Current Simplifications
- Single lumped rigid body, not per-wing or per-control-surface aerodynamics.
- Lift/drag are central forces, so aerodynamic center and pitching moments are not modeled.
- Side force is effectively disabled by the default table.
- No explicit stall state; stall-like behavior comes from lift/drag table shape and pitch limiters.
- Pitch limiters are control limiters, not force cheats.
- Remote multiplayer planes are visual replicas, not locally re-simulated aircraft.
