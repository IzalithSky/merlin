# Plane Physics Spec

## Scope
This document explains the principles behind the current simplified aircraft physics model.

Relevant implementation files:

- `res://scripts/plane_character_controller.gd`
- `res://scenes/plane_character.tscn`
- `res://scripts/plane_aero_tables_store.gd`

The model is intentionally simplified. It is not a full rigid-airframe, per-wing, per-control-surface aerodynamic simulation. It uses a single `RigidBody3D`, central aerodynamic forces, direct control torques, and editable coefficient curves.

## Core Model
The plane is a Godot `RigidBody3D`. Godot/Jolt integrates the body transform, velocity, angular velocity, collisions, and gravity. The controller script computes and applies the forces and torques that represent flight behavior.

The controller applies:

- engine thrust
- lift from an angle-of-attack coefficient table
- drag from an angle-of-attack coefficient table
- optional side force from a sideslip coefficient table
- extra linear drag to prevent indefinite acceleration
- angular drag to make rotations naturally decay
- control torque from player or bot inputs
- directional stability torque that turns the nose toward the movement direction

The scene's numeric tuning, such as mass, thrust, drag, torque, and limiter thresholds, is treated as editable balancing data. The principles below describe how those values are used, not what their current values happen to be.

## Axis Conventions
The aircraft axes come from the rigid body's transform:

```text
forward_axis = -global_transform.basis.z
right_axis = global_transform.basis.x
up_axis = global_transform.basis.y
```

Player controls are mapped into local pitch, yaw, roll, and throttle commands. Pitch input is sign-adjusted so the desired gameplay mapping is preserved while still applying torque in Godot's local-axis convention.

## Simulation Authority
Planes run in one of three authority modes.

Local player:

- Reads local input.
- Simulates forces and torques locally.
- Emits network snapshots when multiplayer is active.

Bot-controlled plane:

- Receives target inputs from `PlaneBotPilot`.
- Uses the same physics path as a local player.
- In multiplayer, bot authority is server-side.

Remote replica:

- Does not simulate flight forces locally.
- Receives transform snapshots from the owning peer/server.
- Applies received position and orientation as visual replication.

This means multiplayer is snapshot replication, not deterministic lockstep physics replay.

## Per-Tick Flow
For a locally simulated plane, each physics tick follows this sequence:

1. Gather or smooth control inputs.
2. Cache frame-local quantities such as body axes, air-relative velocity, airspeed, airflow direction, and dynamic pressure.
3. Compute angle of attack and sideslip from the air-relative velocity in body-local space.
4. Apply thrust.
5. Apply pitch limiters to the requested pitch input.
6. Apply control torque.
7. Apply table-driven aerodynamic lift, drag, and optional side force.
8. Apply extra linear drag and angular drag.
9. Apply directional stability torque.
10. Emit a network state snapshot when the sync interval elapses.

The controller caches quantities that are reused later in the tick so the same velocity, basis, speed, and dynamic-pressure values are not recomputed throughout the force model.

## Input Model
The player controls pitch, yaw, roll, and throttle. Input channels are smoothed so controls ramp rather than instantly snapping. Rotation inputs decay toward neutral when released. Throttle is persistent: it moves up or down when commanded, then holds its current setting.

The bot writes desired control inputs through the same input interface. The plane controller then smooths bot inputs and sends them through the same limiter, torque, drag, and aerodynamic force path used by the player.

This is important: bots do not use a separate flight model.

## Air-Relative State
The aerodynamic model is based on aircraft motion relative to air, not just global velocity.

```text
v_air = linear_velocity - ambient_wind_velocity_world
```

If wind is zero, air-relative velocity is the same as body velocity. If wind is added later, the same formulas continue to work because lift and drag depend on the plane's motion through the air mass.

Dynamic pressure is computed using the standard lift/drag relation:

```text
q = 0.5 * air_density * |v_air|^2
```

Angle of attack and sideslip are computed by transforming `v_air` into the aircraft's local frame:

```text
flow_forward = -v_air_local.z
flow_up = v_air_local.y
flow_right = v_air_local.x
forward_plane_speed = sqrt(flow_forward^2 + flow_up^2)

angle_of_attack = -atan2(flow_up, flow_forward)
sideslip = atan2(flow_right, forward_plane_speed)
```

Below a minimum aerodynamic speed threshold, angle of attack and sideslip are treated as neutral so low-speed numerical noise does not create unstable forces.

## Thrust
Throttle is converted into a normalized thrust fraction, then applied along the aircraft forward axis:

```text
throttle_fraction = normalized_throttle_input
F_thrust = forward_axis * throttle_fraction * max_thrust
```

Thrust is applied as a central force. The engine does not create an offset moment by itself.

## Control Torque
Control authority comes from an editable curve sampled by total air-relative speed magnitude:

```text
control_coefficient = control_authority_curve(|v_air|)
control_torque_scale = base_control_torque * max(control_coefficient, 0)
```

Pitch, yaw, and roll then use axis multipliers:

```text
pitch_torque = limited_pitch_input * control_torque_scale * pitch_axis_multiplier
yaw_torque = yaw_input * control_torque_scale * yaw_axis_multiplier
roll_torque = roll_input * control_torque_scale * roll_axis_multiplier
```

The torque vector is transformed from local aircraft axes into world space and applied directly at the rigid body's center of mass with `apply_torque()`.

Current design choice: control torques are not modeled as offset force couples at wings or tail. That avoids unnecessary complexity while keeping pitch, yaw, and roll behavior explicit and tunable.

## Pitch Limiters
Pitch limiters only reduce requested pitch input. They do not directly change lift, drag, thrust, velocity, gravity, position, or angle of attack.

The limiter stack is:

```text
requested_pitch
  -> max_lift_turn_limiter
  -> sustain_turn_limiter
  -> limited_pitch
```

Both player and bot input pass through this path unless the caller explicitly changes limiter mode.

### Max-Lift Turn Limiter
The max-lift limiter prevents pitch input from commanding angle of attack beyond the peak lift region of the lift curve.

It derives positive and negative max-lift angle of attack from the lift coefficient table:

- Positive max-lift AoA is the positive table point with the highest lift coefficient.
- Negative max-lift AoA is the negative table point with the strongest negative lift coefficient.

Behavior:

- Near the positive max-lift AoA, nose-up pitch authority fades out.
- Nose-down recovery remains available.
- Near the negative max-lift AoA, nose-down pitch authority fades out.
- Nose-up recovery remains available.

The result is a control limiter, not a stall simulation. Stall-like behavior must come from the shape of the lift and drag tables.

### Sustain-Turn Limiter
The sustain limiter attempts to keep turns energy-sustainable by limiting pitch input to an angle of attack whose drag demand can be supported by available forward force.

Available forward force is projected along the current airflow/movement direction:

```text
available = dot(F_thrust, airflow_direction) + dot(F_gravity, airflow_direction)
```

This captures the key energy effect:

- In descending flight, gravity contributes to available forward force.
- In climbing flight, gravity subtracts from available forward force.

For candidate angles of attack, the limiter estimates required drag using the drag table and extra drag terms:

```text
required = estimated_drag_at_candidate_aoa * drag_margin
```

The limiter samples candidate AoA values from neutral toward the max-lift bound and keeps the largest candidate whose required force does not exceed available force.

The sustain limiter still only limits pitch input. It does not cheat by changing actual forces.

Bot policy:

- While recovering low speed, the bot keeps sustain limiting active.
- Once above its recovery exit speed, the bot can disable sustain limiting and rely on max-lift limiting only.

## Aerodynamic Coefficient Tables
Aerodynamic behavior comes from editable tables:

- `lift_coefficient_table` sampled by angle of attack
- `drag_coefficient_table` sampled by angle of attack
- `side_force_coefficient_table` sampled by sideslip
- `control_authority_coefficient_table` sampled by air-relative speed magnitude

Sampling behavior:

- Table points are sorted by input value.
- Duplicate input values are collapsed.
- Values linearly interpolate between neighboring points.
- Values outside the table range use the nearest edge value.

This gives designers editable curve behavior without requiring code changes.

## Aerodynamic Forces
The force directions are derived from the air-relative movement direction and aircraft orientation.

```text
drag_direction = -airflow_direction
lift_axis = right_axis.cross(airflow_direction)
side_axis = airflow_direction.cross(lift_axis)
```

If an axis degenerates because the vectors are nearly parallel, the controller falls back to body-local up or right axes.

Force magnitudes use the standard coefficient form:

```text
F_drag = q * reference_area * CD(angle_of_attack)
F_lift = q * reference_area * CL(angle_of_attack)
F_side = q * reference_area * CY(sideslip)
```

The total aerodynamic force is:

```text
F_aero = drag_direction * F_drag
       + lift_axis * F_lift
       + side_axis * F_side
```

Aerodynamic forces are currently central forces. The model does not simulate aerodynamic center offsets or pitching moments from lift placement.

## Extra Linear Drag
AoA-derived drag alone may not be enough to bound top speed cleanly, especially in simplified models. The controller therefore supports an extra linear-drag term based on total air-relative speed:

```text
F_extra_drag = -airflow_direction * (
  linear_drag_coefficient * |v_air|
  + quadratic_drag_coefficient * |v_air|^2
)
```

The linear term is useful for low-speed damping. The quadratic term dominates at high speed and is the more physically plausible approximation for air resistance at speed.

This extra drag is not angle-of-attack drag. It is a coarse whole-aircraft drag term used to make the simplified model easier to tune.

## Angular Drag
Angular drag damps pitch, yaw, and roll rates so the aircraft does not spin indefinitely after torque input stops.

The controller transforms angular velocity into local aircraft space and applies per-axis damping:

```text
axis_torque = -sign(axis_rate) * (
  angular_linear_coefficient * abs(axis_rate)
  + angular_quadratic_coefficient * abs(axis_rate)^2
)
```

The resulting local torque is transformed back into world space and applied with `apply_torque()`.

This is separate from Godot's built-in rigid body angular damping. The explicit model is preferred because it is visible, tunable per axis, and can be represented in debug force/torque output.

## Directional Stability
Directional stability is the dart-like behavior that turns the nose toward the air-relative movement direction.

```text
axis = forward_axis.cross(airflow_direction)
angle = forward_axis.angle_to(airflow_direction)
torque = normalize(axis) * angle * alignment_strength * |v_air|
```

The torque is capped by an alignment torque limit when that limit is enabled.

This is a simplified stand-in for stabilizing aerodynamic effects from tail surfaces and fuselage shape. It helps the aircraft self-correct toward its movement direction during falls or low-thrust flight.

## Engine-Level Speed Limiting
The project uses the Jolt physics backend. Jolt/project settings may impose a maximum linear velocity. If speed stops increasing while the HUD still shows positive net force along the movement direction, that is a physics-backend speed cap rather than aerodynamic equilibrium.

This matters when tuning thrust and drag: apparent top speed can come from either force balance or an engine-side velocity limit.

## Debug Forces and HUD
The force debug renderer can display the major force and torque contributors:

- thrust
- lift
- drag
- gravity
- damping / extra drag
- pitch and yaw torque
- roll torque
- alignment torque

The HUD can display basic flight telemetry and optional advanced rows. Advanced rows include angle of attack, input bars, and a force-balance projection.

The force-balance snapshot projects forces onto the current velocity direction:

```text
vhat = normalize(linear_velocity)
```

Projected force rows describe acceleration or deceleration along the current movement direction, not the full force vector.

Display preferences are persisted through the display settings system.

## Aero Table Persistence
Editable graph data is persisted through `plane_aero_tables_store.gd`.

Persisted data includes:

- lift table
- drag table
- control authority table

The side-force table exists on the controller, but persistence support is separate from the flight force model and can be extended later.

## Networking Behavior
Locally simulated planes emit compact transform snapshots for their owning peer.

Snapshots include:

- peer identifier
- position
- orientation

Remote planes apply received snapshots and do not run local flight simulation. This avoids two peers simulating the same aircraft differently, but it also means remote aircraft are visual replicas rather than fully predicted physics bodies.

## Current Simplifications
- One lumped rigid body represents the whole aircraft.
- Lift and drag are central forces.
- Aerodynamic center and control-surface moments are not modeled.
- Side force is optional and table-driven.
- Stall is represented only through coefficient table shape and pitch limiting.
- Pitch limiters are input limiters, not force overrides.
- Multiplayer uses snapshot replication, not deterministic physics replay.
