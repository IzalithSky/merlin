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
- Receives ordered transform snapshots from the owning peer/server.
- Buffers snapshots briefly and renders them with interpolation.
- Extrapolates briefly from replicated linear velocity when the buffer underruns.

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

If the plane is already shot down, the active flight-force block is skipped. The body still falls under passive rigid-body physics and continues emitting snapshots so other peers see the wreck move.

## Ground Impact Damage
Ground impact damage is evaluated from physics contact data, not from aircraft attitude alone.

For locally simulated planes, the controller inspects rigid-body contacts during `_integrate_forces()`. When the plane contacts ground geometry, it reads the contact surface normal and compares it against the plane's movement direction.

The impact angle is computed as:

```text
0 degrees   = movement is parallel to the ground surface
90 degrees  = movement is straight into the ground surface
```

This means shallow, skimming contact produces a small impact angle, while a steep dive into the terrain produces a large impact angle.

The damage rules are:

- below `ground_impact_damage_speed_threshold`: no ground-impact damage
- above `ground_impact_damage_speed_threshold`: proportional damage up to `ground_impact_max_damage`
- at or above `ground_impact_fatal_speed_threshold` and `ground_impact_fatal_surface_angle_deg`: immediate full-HP loss

`ground_impact_fatal_surface_angle_deg` is therefore a "how parallel must the touchdown be to avoid a fatal crash" threshold:

- lower values are stricter
- higher values are more forgiving
- around `15` degrees requires the plane to be nearly parallel to the ground to avoid the fatal branch

In multiplayer, the owning peer detects the contact and reports the measured impact speed and impact angle to the server, and the server applies authoritative damage.

## Input Model
The player controls pitch, yaw, roll, and throttle. Input channels are smoothed so controls ramp rather than instantly snapping. Rotation inputs decay toward neutral when released. Throttle is persistent: it moves up or down when commanded, then holds its current setting.

The bot writes desired control inputs through the same input interface. The plane controller then smooths bot inputs and sends them through the same limiter, torque, drag, and aerodynamic force path used by the player.

This is important: bots do not use a separate flight model.

The player also has runtime control toggles. `toggle_pitch_assist` bypasses both pitch limiter stages when turned off. `toggle_stabilization_assist` disables the player stabilization torques for pitch, roll, and yaw when turned off. `toggle_input_decay` disables the automatic decay-to-neutral behavior for pitch, yaw, and roll inputs, so releasing those controls holds the last commanded input value. All three toggles default to on.

## Relative Roll Control
In addition to direct roll input, the player can fly a relative-roll cursor. Instead of commanding a roll rate, the relative-roll left/right inputs steer a target "up" vector. A closed-loop controller then rolls the aircraft to align its actual up vector with that target, holding the commanded bank hands-off.

Mechanism:

- Left/right input rotates the target-up cursor around the aircraft forward axis at a configurable cursor speed.
- The roll error is the signed angle between the aircraft's current up vector and the target up vector, measured in the plane perpendicular to the forward axis.
- The error is converted into a desired roll rate (proportional, clamped), compared against the actual roll angular velocity, and only then turned into roll input. This is the same rate-damped style used elsewhere, so the controller backs off before overshooting the commanded bank.
- The error is clamped to `relative_roll_max_error_deg`. At 180 degrees the cursor can command a full roll to inverted; a smaller value caps how far from the current bank a single command can target.
- When relative-roll input stops and the result settles within a deadband, the cursor target is reset to the current up vector so it does not fight direct roll input.

The HUD exposes a clock widget for this mode: 12 o'clock is the current up vector and the needle swings toward the commanded bank, reaching 6 o'clock at the 180 degree (inverted) cap. The widget reads the same clamped error the controller uses, so its travel reflects the actual command authority.

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
Throttle is converted into a normalized thrust fraction, scaled by an editable thrust-coefficient table, then applied along the aircraft forward axis:

```text
throttle_fraction = normalized_throttle_input
forward_speed = abs(dot(v_air, forward_axis))
thrust_scale = thrust_coefficient_curve(forward_speed)
F_thrust = forward_axis * throttle_fraction * max_thrust * max(thrust_scale, 0)
```

The thrust coefficient table maps engine output as a multiplier of `max_thrust` against the aircraft's air-relative forward speed. At 1.0 throughout the speed range the behavior is identical to a flat `max_thrust` model. Reducing the coefficient at high speed models thrust falloff under ram drag. Reducing it at low speed models spool-up or compressor limits.

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

For the local player, turning pitch assist off bypasses both limiter stages entirely and feeds the requested pitch input straight into control torque.

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
The sustain limiter keeps nose-up pitch energy-aware. It runs in one of two modes depending on whether the aircraft is trying to climb. Either mode only limits pitch input; neither changes actual forces.

**Drag-balance mode (default).** When the aircraft is not climbing, the limiter restricts pitch input to an angle of attack whose drag demand can be supported by available forward force.

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

**Vy speed-margin mode (climbing).** Drag-balance mode structurally forbids a sustained climb: a climb spends energy, and because climbing makes gravity *subtract* from available forward force, the available term collapses and the pitch cap craters to zero exactly when the pilot is trying to climb. To allow the intended speed-for-altitude trade, the limiter switches modes when the aircraft is climbing.

The climb switch engages when both:

- a valid best-climb speed (Vy) is known, and
- the aircraft is gaining altitude — either world vertical speed is positive past a hysteresis dead-band, or the pilot is commanding enough nose-up pitch intent to start a climb before altitude has visibly risen.

In this mode, nose-up authority is gated by how far current airspeed sits above Vy:

```text
authority = clamp((air_speed - Vy) / margin_speed, 0, 1)
```

Pitch authority is full while airspeed is at or above `Vy + margin_speed` and fades linearly to zero as airspeed bleeds down to Vy. This lets the aircraft convert excess speed into a steep, sustained climb while arresting the pull near Vy rather than dragging toward stall.

Best-climb speed Vy is the air-relative speed that maximizes excess-power climb potential — where `(available_thrust - drag) * speed` is greatest. It is recomputed on a periodic interval from the current aero tables under a max-load-factor constraint, and is exposed to the HUD (value, validity, and whether the Vy gate is currently active).

The sustain limiter still only limits pitch input in either mode. It does not cheat by changing actual forces.

Bot policy:

- While recovering low speed, the bot keeps sustain limiting active.
- Once above its recovery exit speed, the bot disables sustain limiting and relies on max-lift limiting only.
- During ground avoidance and collision avoidance the bot forces sustain limiting off regardless of speed, so the full max-lift pull is available when it is most needed.

## Aerodynamic Coefficient Tables
Aerodynamic behavior comes from editable tables:

- `lift_coefficient_table` sampled by angle of attack
- `drag_coefficient_table` sampled by angle of attack
- `side_force_coefficient_table` sampled by sideslip
- `control_authority_coefficient_table` sampled by air-relative speed magnitude
- `thrust_coefficient_table` sampled by air-relative forward speed (`|v_air · forward_axis|`)

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
Directional stability is a stabilization assist that uses yaw to align the nose with airflow, and damps uncontrolled pitch/roll rotation.

For the local player, this stabilization path can be disabled at runtime with the stabilization-assist toggle. Bots continue using the stabilization path.

```text
if player has no yaw input, or if the aircraft is bot-controlled:
  align nose yaw toward airflow in the horizontal plane

if player has no pitch input:
  damp pitch rate toward zero

if no direct roll input and no relative-roll target is active:
  damp roll rate toward zero
```

Each axis is handled independently. A player may be manually driving pitch while still receiving yaw stabilization, or may be using relative roll while still receiving yaw/pitch stabilization.

Bots reuse only the yaw part of this assist. Bot-pilot steering does not use target-driven yaw; yaw is left neutral and the controller's built-in yaw stabilization aligns the nose with airflow. Bot pitch and roll still come from the bot pilot.

Yaw stabilization uses a directional rate-damped pattern:

```text
desired_rate = clamp(angle_error * gain, ± max_desired_axis_rate)
torque = axis * (desired_rate - local_rate) * response_gain * alignment_strength * |v_air|
```

Pitch and roll stabilization are simpler damping assists:

```text
desired_rate = 0
torque = axis * (desired_rate - local_rate) * response_gain * alignment_strength * |v_air|
```

Torque is capped by `alignment_max_torque`. Small angle/rate deadbands suppress chatter near the settled state.

Important details from the current implementation:

- yaw stabilization is active for bots and for players with no yaw input
- pitch damping is player-only and only opposes pitch rate; it does not try to pitch the nose onto the velocity vector
- roll damping is player-only and only opposes roll rate; it does not try to level wings to world up
- roll damping is disabled while direct roll input is active or while relative-roll control is active

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

The main telemetry block also shows live `Pitch Assist`, `Stabilizers`, and `Input Decay` indicators so the player can see whether the limiter path, stabilization torques, and decay-to-neutral behavior are currently active.

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
- thrust table

All four tables are editable at runtime through the plane aerodynamics editor, which presents each table in a separate tab (Lift, Drag, Control, Thrust). The side-force table exists on the controller but is not yet exposed in the editor.

## Networking Behavior
Locally simulated planes emit compact transform snapshots on a fixed interval.

Snapshots include:

- `tick`
- `position`
- `rotation` as a quaternion
- `linear_velocity`

Remote planes do not run local flight simulation. Instead they keep a short snapshot buffer and render slightly in the past:

- if two snapshots are available, position is interpolated with `lerp` and rotation with quaternion `slerp`
- if only one snapshot is available, position is extrapolated briefly from the replicated linear velocity
- stale or out-of-order ticks are ignored

This keeps remote planes visually smooth without trying to run two independent copies of the same aircraft simulation.

## Health and Shot-Down State

Each `PlaneCharacter` carries a `Health` child node (see `docs/health.md`). When HP reaches zero, `Health` emits `shot_down` and `plane_character_controller` sets `is_shot_down = true`.

**Effect on the per-tick flow:**

The entire control and thrust block is skipped when `is_shot_down` is true. Specifically, `_physics_process` returns immediately after the simulation-authority check, so none of the following run:

- `_apply_bot_inputs` / `_collect_inputs`
- `compute_control_state`
- `apply_thrust`
- `apply_plane_torque`
- `apply_aerodynamic_forces`
- `apply_extra_drag_forces`
- `apply_directional_alignment`

Passive physics — gravity, linear damping, and the Jolt integrator — continue to act on the `RigidBody3D`. The plane tumbles and falls under its own momentum without any active stabilisation.

At the moment of shot-down:

- throttle input is forced fully closed
- explicit angular damping is disabled by setting `angular_damp = 0`
- a one-time random roll spin impulse is added on the locally simulating instance

Two exports control the added tumble impulse:

- `shot_down_roll_spin_min_deg`
- `shot_down_roll_spin_max_deg`

A `FlameTrail` child node (two `GPUParticles3D`) is instantiated and attached at the moment of shot-down, travelling with the wreckage.

The plane is not removed from the scene tree on shot-down. Despawn is left to future match logic.

## Tuning Reference

This section describes the main exports and internal constants that shape aircraft behavior.

### Input and Control Response

- `rot_rate`: how quickly pitch, yaw, and roll input ramp toward a commanded value.
- `rot_decay`: how quickly pitch, yaw, and roll relax back toward neutral when released.
- `thr_rate`: how quickly throttle input changes.
- `max_pitch`, `max_yaw`, `max_roll`: per-axis multipliers applied to the shared control-torque budget.
- `base_control_torque`: base magnitude of player/bot control torque before airspeed-based control-authority scaling.

### Relative Roll Control

- `relative_roll_cursor_speed`: speed at which left/right relative-roll input rotates the target-up cursor.
- `relative_roll_max_error_deg`: maximum bank error the relative-roll cursor is allowed to command.
- `relative_roll_error_to_rate_gain`: converts bank-angle error into desired roll rate.
- `relative_roll_max_desired_rate`: hard cap on desired roll rate from the relative-roll controller.
- `relative_roll_rate_response_gain`: converts roll-rate error into actual roll input.
- `relative_roll_deadband_deg`: bank-angle error threshold below which the controller is treated as settled.
- `relative_roll_rate_deadband`: roll-rate threshold below which the controller is treated as settled.

### Propulsion and Aerodynamics

- `max_thrust`: maximum engine force before thrust-table scaling.
- `air_density`: density used for dynamic-pressure calculations.
- `reference_area`: area term used in the coefficient-form lift/drag/side-force equations.
- `ambient_wind_velocity_world`: world-space wind vector subtracted from rigid-body velocity to produce air-relative velocity.
- `lift_coefficient_table`: angle-of-attack to lift coefficient curve.
- `drag_coefficient_table`: angle-of-attack to drag coefficient curve.
- `side_force_coefficient_table`: sideslip to side-force coefficient curve.
- `control_authority_coefficient_table`: airspeed to control-authority multiplier curve.
- `thrust_coefficient_table`: forward airspeed to thrust multiplier curve.

### Directional Stability and Drag

- `alignment_strength`: gain for stabilization torque after per-axis rate error is computed.
- `alignment_max_torque`: cap on the alignment torque so stability assist cannot spike arbitrarily hard at high speed.
- `alignment_angle_to_rate_gain`: converts yaw misalignment angle into a desired local yaw rate.
- `alignment_max_desired_axis_rate`: hard cap on desired yaw stabilization rate.
- `alignment_rate_response_gain`: gain applied to yaw alignment and pitch damping before converting them into stabilization torque.
- `alignment_deadband_deg`: yaw-angle threshold below which yaw stabilization is treated as settled when yaw rate is also small.
- `alignment_rate_deadband`: pitch/yaw rate threshold below which stabilization is treated as settled.
- `relative_roll_rate_response_gain`, `relative_roll_rate_deadband`: reused by passive roll damping when direct roll and relative roll are both inactive.
- `extra_linear_drag_linear_coefficient`: coarse drag term proportional to speed.
- `extra_linear_drag_quadratic_coefficient`: coarse drag term proportional to speed squared; usually the main top-speed limiter in the simplified model.
- `extra_angular_drag_linear_coefficients`: per-axis linear angular damping coefficients in local pitch/yaw/roll space.
- `extra_angular_drag_quadratic_coefficients`: per-axis quadratic angular damping coefficients in local pitch/yaw/roll space.

### Max-Lift Turn Limiter

- `max_lift_turn_limiter_enabled`: master switch for the max-lift input limiter.
- `max_lift_turn_limiter_min_airspeed`: airspeed below which the limiter stays inactive to avoid noisy low-speed behaviour.
- `max_lift_turn_limiter_fade_deg`: angle-of-attack band over which pitch authority fades out as the lift peak is approached.

### Sustain-Turn / Vy Limiter

- `sustain_turn_limiter_enabled`: master switch for the energy-aware sustain limiter.
- `sustain_turn_limiter_min_target_airspeed`: floor speed used by the drag-balance path when estimating sustainable turn conditions.
- `sustain_turn_limiter_fade_deg`: angle-of-attack fade band for the sustain limiter.
- `sustain_turn_limiter_samples`: number of candidate AoA samples checked when solving the drag-balance sustain limit.
- `sustain_turn_limiter_drag_margin`: safety factor applied to estimated drag demand.
- `sustain_turn_vy_enabled`: enables the climb-specific Vy gate.
- `sustain_turn_vy_update_interval`: how often the best-climb-speed estimate is recomputed.
- `sustain_turn_vy_sample_min_speed`: lower bound of the speed sweep used when solving for Vy.
- `sustain_turn_vy_sample_max_speed`: upper bound of the speed sweep used when solving for Vy.
- `sustain_turn_vy_sample_count`: number of sampled speeds in the Vy search.
- `sustain_turn_vy_max_load_factor`: load-factor cap used while evaluating Vy candidates.
- `sustain_turn_vy_margin_speed`: speed margin above Vy that grants full pitch authority in climb mode.
- `sustain_turn_vy_climb_speed_threshold`: vertical-speed hysteresis around zero for deciding whether altitude is rising.
- `sustain_turn_vy_min_vertical_pull_intent`: minimum upward pull intent that allows Vy mode to engage at climb entry before vertical speed becomes clearly positive.

### Ground Impact Damage

- `ground_impact_damage_speed_threshold`: minimum impact speed that begins applying ground-impact damage.
- `ground_impact_fatal_speed_threshold`: minimum impact speed that allows the fatal crash branch.
- `ground_impact_fatal_surface_angle_deg`: minimum angle between movement direction and contacted ground surface that makes a sufficiently fast impact fatal.
- `ground_impact_max_damage`: maximum proportional damage from a non-fatal ground impact.

### Shot-Down Behavior

- `shot_down_roll_spin_min_deg`: minimum one-shot random roll spin impulse applied when the plane is shot down.
- `shot_down_roll_spin_max_deg`: maximum one-shot random roll spin impulse applied when the plane is shot down.

### Networking and Debug

- `network_sync_interval`: interval between emitted local snapshots for multiplayer replication.
- `debug_force_vectors_enabled`: enables local force/torque debug rendering.
- `team_id`: simple team identifier used by hostility checks and targeting colour logic.
- `flame_trail_scene`: packed scene instantiated on shot-down to visually mark the wreck.

## Core Internal Constants

- `MIN_AERODYNAMIC_SPEED_SQUARED`: below this, air-relative speed is treated as effectively zero to avoid unstable AoA/sideslip math.
- `MIN_DIRECTION_VECTOR_LENGTH_SQUARED`: guard threshold for normalizing derived direction vectors such as lift axes or relative-roll targets.
- `MIN_ANGULAR_SPEED_SQUARED`: guard threshold below which explicit angular-drag computation is skipped.
- `GROUND_IMPACT_COOLDOWN_SECONDS`: minimum time between ground-impact damage evaluations so one hard contact does not spam repeated hits every physics step.
- `REMOTE_INTERPOLATION_DELAY`: how far remote replicas render behind real time to keep a two-snapshot interpolation window.
- `REMOTE_MAX_SNAPSHOTS`: maximum buffered remote snapshots retained per replica.
- `TABLE_SORT_EPSILON`: epsilon used when collapsing or sampling nearly duplicate aero-table X values.

---

## Current Simplifications
- One lumped rigid body represents the whole aircraft.
- Lift and drag are central forces.
- Aerodynamic center and control-surface moments are not modeled.
- Side force is optional and table-driven.
- Stall is represented only through coefficient table shape and pitch limiting.
- Pitch limiters are input limiters, not force overrides.
- Multiplayer uses snapshot replication, not deterministic physics replay.
