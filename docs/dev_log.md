# Merlin Dev Log

Date: May 28, 2026

## Summary

This project now has a working menu -> lobby -> world loop, dynamic player character spawning, basic multiplayer movement replication, and a migrated world scene with environment assets.

## Completed Work

1. Project setup and world migration
- Migrated `world_0.tscn` terrain/environment content from sibling project.
- Kept level/environment nodes and excluded unrelated world objects.
- Verified skybox + lighting + imported textures/mesh references in Godot 4.

2. Camera and movement prototype
- Added controllable camera behavior with:
  - `WASD` horizontal movement
  - `R/F` vertical movement
  - Mouse yaw + pitch with pitch clamped to +/- 89 degrees
- Normalized movement input vector so diagonal movement is not faster.
- Added inertia using acceleration/deceleration and velocity integration.

3. UI flow
- Added main menu with:
  - New Game (solo)
  - Host Game
  - Join Game
  - Exit
- Added in-game menu with:
  - Restart
  - Main Menu
  - Exit

4. Lobby and session management
- Added `Lobby` autoload singleton to own session state and scene transitions.
- Added lobby stage UI showing players and ready state.
- Added host-controlled `Allow Join In Progress` option.
- Added join rejection path when game already in progress and joining is disabled.

5. Character spawning and visibility
- Decoupled camera from static scene setup.
- Added dynamic player character scene with visible orange marker cube.
- Increased marker cube size and made it opaque.
- Implemented server-driven spawn assignment.

6. Multiplayer world replication
- Added world-level spawner coordinator:
  - Client handshake: `request_world_sync`
  - Server spawn replication: `spawn_character`
  - Server movement relay path
- Added late-join spawn placement around spawn center without teleporting existing players.

7. Ownership and RPC fixes
- Fixed local ownership conflicts where multiple clients could control same character.
- Enforced per-peer local ownership after spawn messages.
- Fixed signal binding for local control events.
- Added world-ready peer gating so server does not send world RPCs to peers still outside world scene.
- Removed RPC path spam (`Node not found: "world"`) by filtering outbound world RPC targets.

8. Warning/error cleanup
- Fixed shadowed variable warnings (`position`, `is_connected`) in GDScript.
- Fixed mouse grab timing warnings by deferring capture and checking focus state.
- Fixed unique ID calls in no-peer mode.

## Current Multiplayer Model

- Transport: `ENetMultiplayerPeer` backend via Godot high-level multiplayer API.
- Topology: host/server with client join.
- Authority model today:
  - Session/lobby is server authoritative.
  - Movement is client-driven with server relay (not fully server-authoritative physics yet).

## Known Gaps

- Server does not yet validate movement envelopes (max speed, acceleration, teleport checks).
- Remote movement smoothing/interpolation is minimal (direct state application).
- No reconciliation/prediction framework yet for secure authoritative movement.

---

Date: May 29, 2026

## Update Summary

Major follow-up work was completed to migrate the flight-style character pipeline and make local presentation deterministic per peer.

## Completed Work (Update)

1. Plane character migration and defaults
- Migrated `jet` behavior into `plane` naming and assets.
- Set world character spawning default to plane type.
- Kept original cube/camera character type available as alternate enum option.

2. Multiplayer spawn/control fixes
- Fixed ownership/control edge cases where peers could end up controlling the wrong character.
- Added roll replication to multiplayer state pipeline (`position + yaw + pitch + roll`).
- Eliminated world transition race causing RPC path failures on `/root/world` by deferring start-game world RPC broadcast until after scene swap.

3. Flight dynamics restoration/tuning
- Preserved Vimana-style speed-based control authority scaling (`speed_factor` based on forward speed and limiter state).
- Restored and tuned directional alignment behavior so aircraft nose aligns toward travel vector (dart-like fall behavior), with torque clamp for stability.
- Tuned control/thrust defaults for the larger placeholder plane body.

4. Camera / UI / character decoupling
- Removed camera from `plane_character` scene and controller.
- Added independent local camera rig scene/script instantiated at runtime.
- Added independent local telemetry HUD scene/script instantiated at runtime.
- Bound camera + HUD dynamically to the local player character on world start and ownership updates.

5. Telemetry HUD
- Added local HUD metrics:
  - Forward-axis airspeed (`dot(linear_velocity, -forward)`).
  - Vertical speed (`linear_velocity.y`).
  - Altitude (`global_position.y`).
- Ensured metrics are local-target derived and not mixed across peers.

6. Verification
- Script parse checks passed for touched scripts.
- Headless scene load checks passed for new camera/HUD scenes and world scene.
- Host/client probes verified:
  - local camera rig targets local peer character
  - local HUD targets local peer character
  - no cross-peer presentation binding

---

Date: May 30, 2026

## Quirky Findings and Root Causes

1. "Why does speed stop at exactly 500 m/s even when net forward force is positive?"
- Root cause: Jolt global velocity limiter.
- Setting: `physics/jolt_physics_3d/limits/max_linear_velocity = 500.0`.
- Effect: plane can report `Net . vhat > 0` while speed stays pinned at 500.
- This is engine-level clamping, not aerodynamic equilibrium.

2. "Drag arrow looks small vs thrust at high speed"
- Root cause: comparing raw vector magnitudes instead of along-velocity contribution.
- Correct interpretation is projection on velocity direction (`.vhat`), not visual length alone.
- Added HUD force-balance readout:
  - `Thrust . vhat`
  - `Drag . vhat`
  - `Gravity . vhat`
  - `Damping . vhat`
  - `Net . vhat`

3. "Camera appears to slide back during acceleration"
- Root cause: camera rig root used positional lerp follow (`follow_lerp_speed = 12`) creating lag under acceleration.
- Fix: camera follow now snaps to target by default (`follow_lerp_speed = 0`), with optional smoothing only if explicitly enabled.
- Also centered camera pitch pivot to aircraft center (removed Y offset).

4. "Hidden resistive terms vs shown forces"
- Earlier debug arrows showed scripted forces but not all engine contributions.
- Added damping force debug arrow using `PhysicsDirectBodyState3D.total_linear_damp`.
- With current setup (`linear_damp_mode = REPLACE`, `linear_damp = 0`) damping is normally zero unless areas contribute.

---

Date: June 6, 2026

## Bot Chase Tuning Baseline Snapshot

Before tuning the bot chase/slalom behavior, the current `PlaneBotPilot` constants and exports were recorded as the baseline.

### Constants

- `GROUND_AVOIDANCE_MIN_NOSE_UP_INPUT = 0.25`
- `GROUND_AVOIDANCE_PITCH_RESPONSE_RATE = 1.2`
- `SPEED_RECOVERY_PITCH_RESPONSE_RATE = 0.35`
- `SPEED_RECOVERY_FULL_THROTTLE_INPUT = 1.0`
- `SPEED_RECOVERY_TARGET_ABOVE_MAX_NADIR_BLEND = 0.15`
- `SPEED_RECOVERY_PITCH_ANGLE_TO_RATE_GAIN = 1.2`
- `SPEED_RECOVERY_PITCH_RATE_RESPONSE_GAIN = 0.75`
- `SPEED_RECOVERY_MAX_DESIRED_PITCH_RATE = 1.4`
- `SPEED_RECOVERY_YAW_ANGLE_TO_RATE_GAIN = 0.8`
- `SPEED_RECOVERY_YAW_RATE_RESPONSE_GAIN = 0.5`
- `SPEED_RECOVERY_MAX_DESIRED_YAW_RATE = 0.8`
- `SPEED_RECOVERY_WINGS_LEVEL_MIN_FORWARD_SPEED = 60.0`
- `SPEED_RECOVERY_WINGS_LEVEL_MAX_DIVE_ANGLE_DEG = 20.0`
- `HALF_THROTTLE_INPUT = 0.0`
- `LEVEL_FLIGHT_PITCH_RESPONSE_RATE = 0.6`
- `LEVEL_FLIGHT_VERTICAL_SPEED_GAIN = 0.012`
- `ALTITUDE_CAPTURE_TOLERANCE = 10.0`
- `ALTITUDE_HOLD_PITCH_RESPONSE_RATE = 0.45`
- `ALTITUDE_HOLD_MAX_VERTICAL_SPEED = 20.0`
- `ALTITUDE_HOLD_ALTITUDE_GAIN = 0.08`
- `ALTITUDE_HOLD_VERTICAL_SPEED_GAIN = 0.025`
- `LEVEL_TURN_ROLL_RESPONSE_RATE = 0.9`
- `LEVEL_TURN_YAW_RESPONSE_RATE = 0.5`
- `LEVEL_TURN_ROLL_GAIN = 1.4`
- `WINGS_LEVEL_ROLL_GAIN = 1.2`
- `ROLL_RATE_RESPONSE_GAIN = 0.75`
- `ROLL_MAX_DESIRED_RATE = 1.8`
- `ROLL_RATE_DEADBAND = 2.0 deg/s equivalent`
- `CHECKPOINT_ORBIT_RADIAL_CORRECTION = 0.7`
- `CHECKPOINT_ORBIT_RADIUS_DEADBAND = 0.05`
- `TURN_FULL_PULL_ANGLE_RAD = PI * 0.5`
- `TURN_PITCH_ANGLE_TO_RATE_GAIN = 0.85`
- `TURN_PITCH_RATE_RESPONSE_GAIN = 0.75`
- `TURN_MAX_DESIRED_PITCH_RATE = 1.4`
- `TURN_MIN_PULL_ANGLE_RAD = 0.02`
- `TURN_ANGLE_DEADBAND_RAD = PI / 180.0`
- `CORRECTION_TURN_PITCH_DOWN_RATE = 0.47`
- `CORRECTION_TURN_MIN_LATERAL_ANGLE_RAD = 0.08`
- `CORRECTION_TURN_HYSTERESIS_RAD = 2.0 deg`
- `WINGS_LEVEL_DEADBAND_RAD = PI / 180.0`
- `PLAYER_TARGET_REACQUIRE_INTERVAL = 0.5`
- `GROUND_PROBE_EXCLUSION_REFRESH_INTERVAL = 1.0`
- `GROUND_PROBE_SAFE_INTERVAL = 0.25`
- `GROUND_PROBE_NEAR_CLEARANCE_MULTIPLIER = 2.0`
- `GROUND_PROBE_FAST_CLOSURE_RATIO = 0.25`
- `CONTROL_INPUT_LIMIT = 1.0`

### Exports

- `telemetry_sample_interval = 0.2`
- `telemetry_max_samples = 25`
- `min_acceptable_forward_speed = 80.0`
- `reserve_forward_speed = 120.0`
- `max_lift_turn_min_forward_speed = 120.0`
- `default_altitude = 5000.0`
- `min_ground_clearance = 300.0`
- `ground_clearance_tolerance = 25.0`
- `ground_avoidance_time_to_impact = 4.0`
- `ground_avoidance_closure_rate_for_max_pull = 120.0`
- `ground_avoidance_dive_angle_for_max_pull_deg = 35.0`
- `ground_probe_distance = 1000.0`
- `checkpoint_orbit_radius = 500.0`
- `checkpoint_orbit_direction = 1.0`
- `correction_turn_small_angle_deg = 12.0`
- `overshoot_closure_tolerance = 0.5`
- `overshoot_throttle_gain = 0.08`
- `killzone_min_distance = 300.0`
- `killzone_max_distance = 500.0`
- `killzone_base_radius = 100.0`
- `debug_bot_visuals_enabled = true`

## Bot Chase Benchmark Samples at 4x

Benchmark command pattern:

```bash
Godot_v4.6.1-stable_linux.x86_64 --headless --fixed-fps 240 --path /ssd2/projects/godot/merlin --scene res://scenes/bot_chase_debug.tscn -- --bot-chase-benchmark=120 --bot-chase-time-scale=4
```

The score is accumulated at up to `1.0` point per simulated second, based on distance to the moving target's killzone.

### Samples

| Variant | Score | Avg Score/s | Final Killzone Dist | Off-Nose Mean / SD | Range Mean / Median | Closure Mean / SD | Notes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Baseline snapshot | 9.30 | 0.077 | 1254 m | 50.6 / 29.6 deg | 1437 / 1613 m | -4.6 / 63.5 m/s | Pure pursuit of moving killzone; bot tends to lag and slalom. |
| Softer roll/correction constants | 8.27 | 0.069 | 2652 m | 54.8 / 31.0 deg | 2032 / 2457 m | -16.2 / 68.3 m/s | Rejected; less control authority made the chase worse. |
| Lead gain 0.8, max lead 4 s | 10.87 | 0.091 | 965 m | 53.8 / 32.3 deg | 1159 / 1244 m | -2.1 / 64.1 m/s | Better intercept geometry, still weak. |
| Lead gain 1.2, max lead 5 s | 11.18 | 0.093 | 799 m | 57.3 / 32.2 deg | 914 / 930 m | -0.5 / 62.4 m/s | Better range, more off-nose error. |
| Lead gain 1.6, max lead 6 s | 16.35 | 0.136 | 526 m | 62.2 / 33.4 deg | 784 / 757 m | 1.6 / 67.1 m/s | Much better score and final distance. |
| Lead gain 2.0, max lead 7 s, no taper | 18.59 | 0.155 | 285 m | 70.8 / 35.9 deg | 710 / 683 m | 3.9 / 74.8 m/s | Best raw intercept, but too much off-nose/closure spread. |
| Lead gain 2.0, max lead 7 s, full lead by 1400 m | 12.81 | 0.107 | 772 m | 53.9 / 34.3 deg | 1036 / 934 m | -0.3 / 73.2 m/s | Taper too conservative; score regressed. |
| Lead gain 2.0, max lead 7 s, full lead by 700 m | 19.11 | 0.159 | 326 m | 59.3 / 34.4 deg | 813 / 721 m | 3.4 / 70.6 m/s | Kept; best score with lower off-nose than no-taper lead. |
| Lead gain 2.0, max lead 7 s, full lead by 500 m | 18.63 | 0.155 | 610 m | 65.4 / 34.9 deg | 775 / 732 m | 1.9 / 74.8 m/s | Rejected; score and final distance regressed. |

### Tuning Outcome

The main fix is not weaker control. Weakening roll and correction response made the bot fall farther behind. The useful change is moving-target killzone lead steering: the bot still scores against and tries to occupy the true killzone, but it aims at a bounded projected killzone while outside it.

Final kept follow-steering constants:

- `FOLLOW_STEERING_LEAD_GAIN = 2.0`
- `FOLLOW_STEERING_MAX_LEAD_TIME = 7.0`
- `FOLLOW_STEERING_MIN_LEAD_DISTANCE = 100.0`
- `FOLLOW_STEERING_FULL_LEAD_DISTANCE = 700.0`

## Bot Chase Off-Nose Tuning Pass

The previous kept tune improved killzone score with moving-target lead steering, but the bot still showed excessive off-nose angle and occasional pass-through/reversal against a straight-moving target. The key issue was arrival energy: follow throttle only reduced after the bot was already inside the killzone, so it could enter too fast, overshoot, and then need a hard turn back.

Benchmark command pattern stayed the same as the earlier chase samples, with 120 simulated seconds at 4x game speed. Benchmark metric output now includes `p90` and `max` so off-nose spikes are visible instead of being hidden by mean/standard deviation.

### Samples

| Variant | Score | Avg Score/s | Final Killzone Dist | Off-Nose Mean / Median / P90 / Max / SD | Range Mean / Median | Closure Mean / P90 / Max / SD | Notes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Previous kept lead tune | 19.11 | 0.159 | 326 m | 59.3 / 53.0 / n/a / n/a / 34.4 deg | 813 / 721 m | 3.4 / n/a / n/a / 70.6 m/s | Good intercept score, but visibly slalomed and sometimes overshot hard. |
| Lead cap at 1 killzone length | 10.62 | 0.088 | 1044 m | 52.6 / 48.8 / n/a / n/a / 29.7 deg | 1182 / 1323 m | -2.8 / n/a / n/a / 61.6 m/s | Rejected; cleaner angle but too weak to catch. |
| Lead cap at 2 killzone lengths | 11.13 | 0.093 | 922 m | 54.4 / 51.0 / n/a / n/a / 31.1 deg | 1033 / 1107 m | -1.6 / n/a / n/a / 61.7 m/s | Rejected; still too weak. |
| Lead cap at 4 killzone lengths | 14.56 | 0.121 | 670 m | 57.7 / 56.4 / n/a / n/a / 32.2 deg | 849 / 825 m | 0.6 / n/a / n/a / 64.6 m/s | Rejected; score did not recover enough. |
| Early throttle slowdown at 3.0x tolerance | 16.74 | 0.139 | 897 m | 47.2 / 48.6 / n/a / n/a / 20.6 deg | 781 / 772 m | -0.3 / n/a / n/a / 43.3 m/s | Very clean angle, but brakes too early and falls behind. |
| Early throttle slowdown at 2.0x tolerance | 21.86 | 0.182 | 732 m | 53.7 / 50.2 / 88.8 / 112.3 / 28.5 deg | 777 / 745 m | 0.5 / 79.8 / 103.1 / 61.5 m/s | Best score, but keeps more high-angle spikes. |
| Early throttle slowdown at 2.1x tolerance | 21.71 | 0.181 | 819 m | 53.0 / 49.2 / 87.1 / 108.5 / 27.5 deg | 771 / 748 m | -0.1 / 75.5 / 97.4 / 59.3 m/s | Better spikes than 2.0 with little score loss. |
| Early throttle slowdown at 2.2x tolerance | 21.51 | 0.179 | 914 m | 52.4 / 50.2 / 85.7 / 104.4 / 26.4 deg | 765 / 747 m | -0.8 / 73.0 / 92.2 / 57.0 m/s | Kept for this off-nose-focused pass. |
| Early throttle slowdown at 2.25x tolerance | 21.25 | 0.177 | 949 m | 52.0 / 50.5 / 84.7 / 102.1 / 25.9 deg | 765 / 748 m | -1.0 / 70.7 / 90.5 / 55.8 m/s | Cleanest off-nose spikes, but slightly more distance loss. |

### Outcome

The kept change is early follow-throttle reduction when the bot is closing fast and is near the killzone. This leaves the successful lead steering intact, but stops adding thrust before the bot passes through the desired trailing volume. For the off-nose-focused pass, `FOLLOW_THROTTLE_SLOWDOWN_DISTANCE_SCALE = 2.2` is the best compromise tested: score improves over the previous kept lead tune, while off-nose mean and closure spread both fall.

## Bot Killzone Volume Change

The bot killzone changed from a point with spherical tolerance to a truncated cone behind the target. The current defaults are:

- `killzone_min_distance = 300.0`
- `killzone_max_distance = 500.0`
- `killzone_base_radius = 100.0`

The cone apex would be at the target, but the top is cut off at the minimum distance. Radius therefore grows linearly with distance along the target's rear axis and reaches the base radius at max distance. The bot steers toward the cone centerline midpoint, while containment, throttle slowdown, debug visualization, and chase score use the actual cone volume.

A 120 second chase-debug benchmark at 4x with the cone volume produced `score = 35.22`, `avg_score_rate = 0.293`, `off_nose_mean = 48.0 deg`, `off_nose_p90 = 73.2 deg`, and `off_nose_max = 78.3 deg`. This is not directly comparable to the previous sphere-score value because the goal volume changed.
