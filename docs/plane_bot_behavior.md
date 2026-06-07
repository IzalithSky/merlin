# Plane Bot Behavior

## Scope
This document explains the principles behind the current plane bot implementation.

Relevant implementation files:

- `res://scripts/plane_bot_pilot.gd`
- `res://scripts/world_character_spawner.gd`
- `res://scripts/plane_character_controller.gd`
- `res://scripts/killzone_cone.gd`

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
`world_character_spawner.gd` creates bot planes and attaches `PlaneBotPilot` on the authority side.

The spawner:

- assigns reserved bot peer IDs
- creates bot spawn states
- spawns bot plane characters
- enables bot control on authority-owned bot planes
- injects a fallback follow target when a static world marker is configured
- passes the player-killzone cone parameters (minimum distance, maximum distance, base radius) into the pilot

The pilot can dynamically scan the scene for player aircraft. It searches the `player_character` group and selects the nearest non-bot plane. If no player plane is available, it falls back to the injected static target.

## Visual Debug
Bot debug visuals are controlled by the persistent display setting exposed in the options menu.

When enabled, each active bot pilot draws:

- current bot mode and target type
- forward-axis arrow
- up-axis arrow
- line to the current intent point (the intercept/climb aim it is steering at)
- the killzone cone outline with a center marker when chasing a target

These visuals are diagnostic only. They do not affect bot state, flight physics, or networking.

## State Priority
Each physics tick follows a fixed priority order.

1. Refresh follow-target velocity and player acquisition.
2. Measure ground clearance.
3. Avoid ground if clearance is unsafe.
4. Recover speed if forward speed is below the acceptable band.
5. Follow the current target when one exists.
6. Hold requested altitude when no target exists.
7. Orbit a configured checkpoint when idle.
8. Fly level as a final fallback.

Safety and energy management intentionally override mission behavior. The bot should not keep chasing a target while below safe speed or too close to terrain.

## Telemetry
The bot stores periodic samples of forward speed and altitude.

The telemetry layer exposes numeric trend values for:

- current forward speed and altitude
- forward-speed delta and approximate acceleration
- altitude delta and approximate vertical speed

These samples are used as bot-readable state, not as physics authority.

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

With a target, the pilot uses the target or killzone destination point as context. If that point is lower than the bot, recovery blends from horizontal travel toward that lower point. If the point is level with or above the bot, recovery stays nearly horizontal toward it instead of pitching up or diving straight away from the fight.

The pitch and yaw requests are rate-damped against local angular velocity. This lets the bot aim at the recovery direction and back off before rotating past it.

Roll behavior during recovery depends on context. If the bot has a follow target, it rolls its lift vector toward the target or killzone destination point while recovering speed. If it has no target and is already slow or steeply diving, wings-level correction is neutralized so it does not keep rolling while it is trying to build speed. Wings-level correction is only used in untargeted recovery once the aircraft has enough speed and is not in a steep dive.

## Turn Limiter Mode
The plane controller has two pitch-input limiter layers:

- max-lift limiting, which prevents pitch input from exceeding the configured max-lift AoA
- sustain-turn limiting, which further reduces pitch input when the requested turn would spend energy faster than available thrust can sustain

The bot can switch the sustain-turn limiter at runtime. Below its max-lift-turn speed threshold, sustain-turn limiting stays enabled so the bot preserves energy. At or above that threshold, the bot disables sustain-turn limiting, leaving max-lift limiting as the active cap.

This mode switch also gates the overshoot climb. The bot only has the pitch authority to zoom-climb when it is fast enough to be in max-lift mode, which is exactly the high-closure situation where overshoot occurs. As a climb bleeds speed back toward the threshold, sustain-turn limiting re-engages and caps the pull, so the bot cannot climb itself into a stall.

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

## Target Following
When a player target exists, the bot does not aim at the player body. It chases a killzone volume trailing the target.

### Killzone Volume
The killzone is a truncated cone behind the target, defined by:

- the target's world position
- the target's backward axis
- a minimum and a maximum trailing distance
- a base radius

The cone apex is at the target and is truncated at the minimum distance. Its radius grows linearly with distance along the rear axis, reaching the base radius at the maximum distance. The bot uses the cone centerline midpoint as its destination point, while containment ("am I in the killzone") tests the actual cone volume. The cone geometry lives in `killzone_cone.gd` and is shared by the pilot, the debug renderer, and the chase scoring.

### Lead Steering
Outside the killzone the bot does not chase the destination point directly. Aiming at a moving point makes a bank-to-turn aircraft weave, because the bearing to it drifts as the target translates. Instead the bot steers at a constant-bearing intercept point: the destination projected forward along the target's velocity by an estimated time-to-go.

Time-to-go is the range to the destination divided by closing speed (the bot's velocity minus the target's velocity along the line of sight), capped to a maximum lead time so a stalled closure (such as a co-speed mutual chase) cannot run the aim away. For a target flying a straight line this intercept point is stationary in world space, so the bot flies a straight path to it with no bearing drift to weave around. Near the slot, or when not closing, the lead shrinks and the behavior collapses back to direct pursuit.

Inside the killzone the bot stops aiming at the destination and aligns with the target's velocity or forward direction, so it does not intentionally bump the target.

### Overshoot Handling
When the bot is closing on the killzone faster than a small tolerance and is already near the cone, it is about to overshoot. It bleeds the excess closure two ways at once:

- Throttle is reduced or cut in proportion to closure speed.
- The aim is raised above the slot so a climb trades the excess closure for altitude (a high-yo-yo). Because the bot is fast in this situation it is already in max-lift mode, so the pull has the authority to actually climb.

The climb is bounded so it cannot misbehave: the raised aim is capped to a fixed ceiling above the slot, and the horizontal aim stays on the slot. Once that much vertical separation is gained the aim levels off (and noses back down if the bot is already higher), so the bot can neither reverse just to climb nor climb away indefinitely. As closure normalizes the climb fades and normal lead steering resumes.

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

## Limits
The bot is still a simple behavior controller, not a full combat AI.

Current limitations:

- It steers with a first-order constant-bearing intercept, not a full predictive solution that anticipates target maneuvers.
- It does not reason about weapons, aspect, or tactical pursuit modes.
- It does not plan terrain routes.
- It uses local reactive decisions rather than long-horizon planning.

Those systems can be added on top of the same state-priority structure without changing the plane physics model.
