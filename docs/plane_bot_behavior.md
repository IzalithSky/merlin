# Plane Bot Behavior

Status: partial — implemented for current single-player and multiplayer bot behavior, but still subject to the larger authority migration and controller split planned in `docs/dev_plan.md`.

## Scope
This document explains the principles behind the current plane bot implementation.

Relevant implementation files:

- `res://scripts/plane_bot_pilot.gd`
- `res://scripts/world_character_spawner.gd`
- `res://scripts/plane_bot_setup.gd`
- `res://scripts/local_plane_presentation_binding.gd`
- `res://scripts/plane_character_controller.gd`
- `res://scripts/display_settings_applier.gd`

The bot is a pilot layer on top of the normal plane character. It does not apply forces, torques, velocity changes, or teleports directly. It writes roll, pitch, yaw, and throttle intentions into the same plane controller used by players.

## Ownership
Bots reuse the same character spawn and replication pipeline as player aircraft.

Authority rules:

- In singleplayer, the local instance simulates bots.
- In multiplayer, the server simulates bots.
- Clients do not run decision logic for remote bots.
- Remote clients receive bot transform snapshots through the normal plane replication path.

This keeps bot decisions authority-side and prevents clients from simulating different outcomes.

## Spawn And Target Setup
`world_character_spawner.gd` still owns the authoritative bot spawn pipeline, but bot-specific setup is now split into `plane_bot_setup.gd`.

The current spawn path:

- records bot entries in the spawn registry and tracks bot identity separately from transport-peer classification
- creates bot spawn states
- spawns bot plane characters
- calls `PlaneCharacter.configure(...)` before the node enters the tree so the controller boots with the correct local/authority state and initial airspeed
- delegates pilot creation and configuration to `PlaneBotSetup`

`PlaneBotSetup` then:

- creates and attaches `PlaneBotPilot` on the authority side only
- injects a fallback follow target when a static world marker is configured
- passes player-killzone distance and tolerance into the pilot

The pilot can dynamically scan the scene for player aircraft. It searches the `player_character` group and selects the nearest non-bot plane. If no player plane is available, it falls back to the injected static target.

## Visual Debug
Bot debug visuals are controlled by the persistent display setting exposed in the options menu.

When enabled, each active bot pilot draws:

- current bot mode and target type
- forward-axis arrow
- up-axis arrow
- line to the current intent point
- marker at the player killzone point when chasing a player

These visuals are diagnostic only. They do not affect bot state, flight physics, or networking.

## State Priority
Each physics tick follows a fixed priority order.

1. Refresh follow-target velocity and player acquisition.
2. Measure ground clearance.
3. Avoid ground if clearance is unsafe.
4. Avoid a closing mid-air collision if one is predicted.
5. Recover speed if forward speed is below the acceptable band.
6. Follow the current target when one exists.
7. Hold requested altitude when no target exists.
8. Orbit a configured checkpoint when idle.
9. Fly level as a final fallback.

Safety and energy management intentionally override mission behavior. The bot should not keep chasing a target while below safe speed or too close to terrain.

## Speed Recovery
Speed recovery is an override that protects the bot from low-energy flight.

When forward speed drops below the acceptable band, the bot stops chasing targets and commands:

- full throttle
- a recovery aim direction derived from speed deficit
- targeted roll behavior when a target exists
- conditional wings-level roll behavior when no target exists

The bot exits recovery only after reaching the reserve speed band. That hysteresis prevents rapid state flicker around the threshold.

Pitch remains the main energy-control tool. Throttle helps, but the bot does not cheat by changing forces directly.

Recovery no longer means "hold nose-down input until speed returns." Without a target, the pilot blends from its current horizontal heading toward nadir in proportion to missing speed. Near the reserve speed band the aim direction is nearly horizontal; with a large speed deficit it approaches straight down.

With a target, the pilot uses the target or killzone point as context. If that point is lower than the bot, recovery blends from horizontal travel toward that lower point. If the point is level with or above the bot, recovery stays nearly horizontal toward it instead of pitching up or diving straight away from the fight.

The pitch and yaw requests are rate-damped against local angular velocity. This lets the bot aim at the recovery direction and back off before rotating past it.

Roll behavior during recovery depends on context. If the bot has a follow target, it rolls its lift vector toward the target or player killzone point while recovering speed. If it has no target and is already slow or steeply diving, wings-level correction is neutralized so it does not keep rolling while it is trying to build speed. Wings-level correction is only used in untargeted recovery once the aircraft has enough speed and is not in a steep dive.

## Turn Limiter Mode
The plane controller has two pitch-input limiter layers:

- max-lift limiting, which prevents pitch input from exceeding the configured max-lift AoA
- sustain-turn limiting, which further reduces pitch input when the requested turn would spend energy faster than available thrust can sustain

The bot can switch the sustain-turn limiter at runtime. Below its max-lift-turn speed threshold, sustain-turn limiting stays enabled so the bot preserves energy. At or above that threshold, the bot disables sustain-turn limiting, leaving max-lift limiting as the active cap.

During ground avoidance and collision avoidance the bot unconditionally forces max-lift mode regardless of current speed. Both states demand maximum pitch authority; sustain-turn limiting would restrict the pull available precisely when it is most critical.

This does not change forces, torques, velocity, or AoA directly. The bot does not run its own AoA, sustain-turn, or max-load pitch limiter. It only sends normalized control intentions; the plane controller decides how much pitch input is physically accepted.

## Ground Avoidance
Ground avoidance is a reactive safety layer.

The bot casts a downward physics ray and measures real ground clearance. The ray excludes plane characters so the bot does not treat aircraft bodies as terrain. The exclusion list is cached and refreshed periodically instead of rebuilt every physics tick.

Ground avoidance can trigger from:

- clearance below the hard safety floor
- predicted time-to-ground based on downward closure rate
- remaining in recovery until clearance has hysteresis margin or the predicted impact risk is gone

When ground is too close, the bot commands:

- full throttle
- nose-up pitch proportional to clearance urgency, downward closure rate, and dive angle
- wings-level roll behavior

This is not path planning. It is only a last-resort collision avoidance behavior.

## Collision Avoidance
Collision avoidance is a reactive safety layer that prevents mid-air collisions between planes. It overrides all mission behavior except terrain avoidance.

Every physics tick the bot scans all other planes in the `player_character` group. For each candidate it computes the time-to-closest-approach (TCA) using relative velocity:

```text
tca = -(offset · rel_vel) / |rel_vel|²
miss_distance = |offset + rel_vel × tca|
```

A threat is confirmed when TCA falls within the lookahead window and the predicted miss distance is smaller than the collision radius. A closing-speed gate is also required: planes that are co-flying, separating, or that the bot is actively trailing in its killzone close at near-zero relative speed and are never treated as threats, even when they are physically close.

The evasion direction is based on the other plane's position in the bot's local frame:

- Other plane in the forward hemisphere: turn right.
- Other plane in the rear hemisphere: turn left.

This rule is symmetric. Two bots on a head-on course each break right, separating them to opposite sides. A faster bot overtaking from behind also breaks left, while the one being overtaken turns right, widening the gap. The maneuver banks to the target angle (`COLLISION_AVOIDANCE_BANK_DEG`) and holds it with a closed-loop roll controller, then pulls hard. The aircraft banks once to the target angle and stays there rather than rolling past it.

The avoidance direction is latched once triggered and held for at least `COLLISION_AVOIDANCE_MIN_DURATION` seconds after the threat clears, preventing rapid flicker if planes oscillate around the detection threshold.

## Target Following
When a player target exists, the bot does not aim at the player body. It computes a killzone point behind the target and chases that point.

The killzone point is derived from:

- the target's world position
- the target's backward axis
- the configured killzone distance

Outside the killzone tolerance the bot uses constant-bearing intercept steering. Rather than aiming at where the killzone point is now, it predicts where the point will be when the bot arrives and aims there:

```text
time_to_go = range / max(closing_speed, MIN_CLOSING_SPEED)
time_to_go = min(time_to_go, FOLLOW_LEAD_MAX_TIME)   # capped at 3 s
steering_point = killzone_point + target_velocity * time_to_go
```

The lead point collapses to the raw killzone point when `time_to_go` approaches zero (bot already at the slot) or when closing speed is too low to estimate a useful lead. Inside the killzone tolerance the bot stops aiming at any computed point and aligns with the target's velocity or forward direction instead. This avoids intentionally bumping into the target.

Throttle during target follow:

- Outside the brake zone, the bot commands full throttle.
- The brake zone begins at `killzone_tolerance × 2.0` from the killzone point, before the bot crosses into the killzone itself.
- When inside the brake zone and closing too fast, throttle is reduced in proportion to closure speed to prevent overshooting.

The bot still steers toward the killzone altitude through pitch. Throttle is not held back just because altitude is not matched.

## Static Fallback And Checkpoints
If no player target is available, the injected static target can keep the bot active. The current idle behavior can also orbit configured checkpoint positions.

Checkpoint orbit is a steering behavior:

- compute a horizontal radial vector from the checkpoint
- compute a tangent direction around that radial vector
- add radial correction toward the orbit radius
- turn toward the resulting desired direction

It is intentionally simple and does not model a full autopilot orbit hold.

## Turning
The bot turns by pointing its lift vector toward the desired direction and then pulling.

Direction-to-control flow:

1. Normalize the desired world-space direction.
2. Transform it into aircraft-local space.
3. Compute a roll target that places the lift vector toward the desired direction.
4. Compute a pitch target from the total turn angle.
5. Smooth roll, pitch, and yaw inputs over time.
6. Send the inputs to `plane_character_controller.gd`.

Roll control is rate-damped. The pilot converts bank or lift-vector error into a desired local roll rate, compares that against the aircraft's current local roll angular velocity, and only then produces roll input. This lets the bot back off or counter-roll before it crosses the target bank angle, instead of waiting for angle error alone to change sign.

Pitch targets are behavior requests, not physical guarantees. The bot may request full pull for a hard turn or escape, but the plane controller remains responsible for max-lift and sustain-turn limiting.

For small lateral target errors near the nose, the bot can briefly pitch down to increase angular separation before doing the normal roll-and-pull turn. This avoids tiny same-heading errors becoming endless shallow corrections.

## Difficulty Tuning
Bot aggression and energy management are governed by three speed thresholds exported on `PlaneBotPilot`:

- `min_acceptable_forward_speed` — the speed below which the bot abandons its target and enters recovery.
- `reserve_forward_speed` — the speed it must reach before it will exit recovery mode (hysteresis prevents flicker).
- `max_lift_turn_min_forward_speed` — the speed above which sustain-turn limiting is disabled, giving the bot full pitch authority for hard turns.

All three thresholds are absolute values in m/s, but their effective meaning depends on the plane model's natural flight envelope. The recommended practice is to set them relative to the plane's optimal cruise and turn speeds:

- A bot that recovers early (high thresholds relative to cruise speed) maintains its energy advantage and is harder to defeat in extended maneuver fights.
- A bot that recovers late (low thresholds) can be drained into stall more easily by a skilled player.
- `max_lift_turn_min_forward_speed` controls when the bot is allowed to trade energy for turn rate; a high value means the bot usually fights energy-conservatively, a low value means it will pull hard even at modest speed.

As a practical baseline, set `min_acceptable_forward_speed` near the plane's minimum safe handling speed, `reserve_forward_speed` near comfortable cruise, and `max_lift_turn_min_forward_speed` slightly above that. Raising all three uniformly makes the bot more conservative and harder to exploit; lowering them makes the bot more reckless and easier to separate from energy.

## Export Reference
All `@export` fields on `PlaneBotPilot` are set by `PlaneBotSetup` or the bot scene and can be overridden per-bot without touching the script.

### Altitude and idle
| Export | Default | Unit | Role |
|---|---|---|---|
| `default_altitude` | 5000 | m | Altitude climbed to at spawn; altitude maintained when no target exists. |
| `checkpoints` | `[(0, 1500, 0)]` | Array[Vector3] | World positions the bot orbits when idle with no follow target. |
| `checkpoint_orbit_radius` | 500 | m | Target orbital radius around each checkpoint. |
| `checkpoint_orbit_direction` | 1.0 | ±1 | Orbit direction: positive = counterclockwise seen from above. |

### Speed recovery and turn limiting
| Export | Default | Unit | Role |
|---|---|---|---|
| `min_acceptable_forward_speed` | 50 | m/s | Forward speed below which the bot abandons its target and enters speed recovery. |
| `reserve_forward_speed` | 90 | m/s | Speed the bot must reach before it exits recovery. Creates hysteresis to prevent flicker. |
| `max_lift_turn_min_forward_speed` | 110 | m/s | Speed above which sustain-turn limiting is disabled, allowing the bot to trade energy for turn rate. |

### Ground avoidance
| Export | Default | Unit | Role |
|---|---|---|---|
| `min_ground_clearance` | 300 | m | Hard clearance floor; avoidance triggers when ray-measured clearance falls below this. |
| `ground_clearance_tolerance` | 25 | m | Hysteresis margin; bot stays in avoidance until clearance exceeds `min_ground_clearance + tolerance`. |
| `ground_avoidance_time_to_impact` | 4 | s | Avoidance also triggers when predicted time-to-ground falls below this, even if absolute clearance is acceptable. |
| `ground_avoidance_closure_rate_for_max_pull` | 120 | m/s | Downward closure rate at which full nose-up input is commanded. |
| `ground_avoidance_dive_angle_for_max_pull_deg` | 35 | deg | Dive angle at which full nose-up input is commanded. |
| `ground_probe_distance` | 1000 | m | Maximum range of the downward ground probe ray. |

### Target following
| Export | Default | Unit | Role |
|---|---|---|---|
| `killzone_distance` | 250 | m | Distance behind the target where the bot aims to fly. |
| `killzone_tolerance` | 150 | m | Radius of the killzone sphere. Inside this the bot aligns with the target rather than steering toward the point. |
| `overshoot_closure_tolerance` | 0.5 | m/s | Closure speed below which throttle braking is not applied even when inside the brake zone. |
| `overshoot_throttle_gain` | 0.08 | — | Throttle reduction per m/s of excess closure speed inside the brake zone. |

### Turning
| Export | Default | Unit | Role |
|---|---|---|---|
| `correction_turn_small_angle_deg` | 12 | deg | Lateral-angle threshold below which the bot pitches down briefly before rolling into a turn. Avoids infinite shallow corrections for tiny heading errors. |

### Debug
| Export | Default | Role |
|---|---|---|
| `debug_bot_visuals_enabled` | true | Enables the 3D debug overlay drawn by each bot pilot. |

### Collision avoidance constants
These are `const` rather than `@export` and must be changed in the script. They are unlikely to need per-bot tuning.

| Constant | Value | Unit | Role |
|---|---|---|---|
| `COLLISION_AVOIDANCE_RADIUS` | 12 | m | Predicted miss distance at CPA below which the threat is confirmed. |
| `COLLISION_AVOIDANCE_LOOKAHEAD` | 1.5 | s | How far ahead in time to check for a predicted collision. |
| `COLLISION_AVOIDANCE_MIN_CLOSING_SPEED` | 40 | m/s | Closing-speed gate; planes closing slower than this are never treated as threats. |
| `COLLISION_AVOIDANCE_BANK_DEG` | 90 | deg | Target bank angle held during the evasive maneuver. |
| `COLLISION_AVOIDANCE_MIN_DURATION` | 0.5 | s | Minimum time the avoidance maneuver is held after the threat clears. |
| `COLLISION_AVOIDANCE_RESPONSE_RATE` | 1.5 | /s | Input ramp rate during the avoidance maneuver. |

## Shot-Down Behaviour

When the bot's own plane is shot down (`is_shot_down == true` on the plane controller), `_physics_process` early-returns immediately. This stops all flight control writes, weapon targeting, and debug visual updates in a single gate. The underlying plane controller also stops applying thrust and control torques at its own gate, so the plane falls freely under physics.

When the bot's **follow target** is shot down, `_update_weapon_targeting` clears it as the desired lock target that frame. The bot continues to fly toward the target geometrically (the flight controller is unaware of HP state), but it stops attempting to lock and fire. A future improvement could make the bot break off and search for a new target when its chase target goes down.

Bots never lock a shot-down plane — `plane_weapon_lock.gd`'s `_is_lockable` filter rejects any target with `is_shot_down == true`, so lock progress resets immediately if a target is shot down mid-lock.

---

## Limits
The bot is still a simple behavior controller, not a full combat AI.

Current limitations:

- It does not reason about weapons, aspect, or tactical pursuit modes.
- It does not plan terrain routes.
- It uses local reactive decisions rather than long-horizon planning.

Those systems can be added on top of the same state-priority structure without changing the plane physics model.
