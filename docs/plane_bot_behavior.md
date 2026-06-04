# Plane Bot Behavior

## Scope
This document explains the principles behind the current plane bot implementation.

Relevant implementation files:

- `res://scripts/plane_bot_pilot.gd`
- `res://scripts/world_character_spawner.gd`
- `res://scripts/plane_character_controller.gd`

The bot is not a separate aircraft model. It is a pilot layer that writes control intentions into the same plane controller used by players.

## Core Idea
A bot plane is a normal plane character with a `PlaneBotPilot` child node attached on the authority side.

The bot pilot:

- observes the plane's current state
- resolves or reacquires a follow target
- chooses a high-level behavior for the current tick
- converts desired movement into roll, pitch, and yaw inputs
- commands throttle from the shared output layer
- sends those inputs to the plane controller

The plane controller then smooths those inputs and applies the normal flight model. The bot does not apply forces, torques, velocity changes, or position changes directly.

## Ownership and Networking
Bots use reserved peer identifiers so they can reuse the same spawn and replication pipeline as player aircraft.

Authority rules:

- In singleplayer, the local instance simulates bots.
- In multiplayer, the server simulates bots.
- Clients do not run bot decision logic for remote bots.
- Remote clients receive bot transform snapshots like they receive player snapshots.

This keeps bot behavior deterministic from the match authority and avoids each client simulating a different bot outcome.

## Spawn and Target Setup
`world_character_spawner.gd` is responsible for creating bot planes and attaching the bot pilot.

The spawner:

- assigns reserved bot peer IDs
- creates bot spawn states
- spawns bot plane characters
- attaches `PlaneBotPilot` only on the authority side
- injects the follow target when available
- passes orbit range and tolerance settings into the pilot

In singleplayer, bot spawn placement uses the same radial participant layout as player spawning. In multiplayer, the server owns bot spawn placement and broadcasts bot spawns to clients.

In singleplayer, the bot pilot periodically scans the character hierarchy for the nearest non-bot plane and uses it as a player target. This follows the same broad principle as Vimana's AI target acquisition: targets are reacquired from live scene objects rather than captured once and assumed valid forever.

If no player plane can be found, the bot falls back to the configured world marker.

In multiplayer, the current bot target fallback remains the configured world marker. Player-targeting for multiplayer is intentionally not enabled yet, because target selection should be server-authoritative and explicit.

The bot pilot can also periodically reacquire a target through its configured node path if the injected target is missing.

## Decision Priority
Each physics tick follows a fixed priority order.

1. Validate or reacquire the follow target.
2. Measure forward speed and update speed trend.
3. Set the plane's sustain-turn limiter mode based on bot energy state.
4. Check terrain avoidance.
5. If terrain danger exists, run terrain escape and skip all lower-priority behaviors.
6. Update speed recovery state.
7. If speed recovery is active, run speed recovery and skip follow/orbit.
8. If there is no target, hold simple neutral controls.
9. If target is a player or outside the orbit band, use pursuit/approach guidance.
10. If fallback target is inside the orbit band, orbit it.

This priority order is intentional: terrain safety overrides energy recovery, and energy recovery overrides mission behavior.

## Terrain Avoidance
Terrain avoidance is a reactive safety layer.

The bot uses ray probes against the physics world:

- A forward probe looks ahead along the current movement direction, falling back to nose-forward if the plane is slow.
- A downward probe checks whether ground clearance is below the safety threshold.

Forward threat response:

- At normal speed, build an escape direction from the collision normal plus an upward bias.
- At low forward speed, project the current movement direction onto the terrain plane instead of forcing a hard climb.
- Convert the escape direction into normal flight controls.
- Apply the strong climb-biased pitch command only when not using terrain-parallel escape.
- Throttle is applied globally by the output layer.

Low-altitude response:

- At normal speed, build a climb direction from nose-forward plus an upward bias.
- At low forward speed, choose a terrain-parallel desired direction instead of a hard climb direction.
- Convert it into controls.
- Skip target following for that tick.

The low-speed terrain-parallel mode exists because hard nose-up terrain avoidance can deepen a stall. When the bot has weak forward speed, preserving a controllable flight path is safer than demanding an immediate climb.

The terrain layer is not path planning. It is immediate obstacle avoidance intended to keep the bot from flying into terrain while the higher-level behavior remains simple.

## Speed Recovery
Speed recovery is an energy-management override.

The bot enters speed recovery when forward speed falls below an entry threshold and exits only after speed rises above a higher exit threshold. The two-threshold design creates hysteresis, so the bot does not flicker in and out of recovery every frame.

While recovering speed, the bot abandons follow/orbit behavior and focuses on regaining airspeed.

The recovery controller uses:

- current forward speed
- speed deficit relative to recovery target
- smoothed forward acceleration trend
- current dive angle
- dive-angle rate
- local pitch rate
- vertical descent speed
- estimated terrain clearance

The main recovery principle is that pitch controls energy more directly than engine command in this model. The bot therefore commands a controlled nose-down attitude when it needs speed, but the command is limited by descent rate and terrain clearance.

Recovery behavior:

- Larger speed deficit allows a stronger nose-down command.
- Pitch command is smoothed over time.
- Pitch-rate damping prevents oscillation.
- Forward-acceleration trend damping reduces overcorrection.
- If the aircraft is already descending too fast, nose-down command is reduced.
- If terrain is close, nose-down command fades or is blocked.
- The bot commands full throttle below its max-speed cap and cuts throttle above it; pitch remains the main speed-control mechanism.

This is a simple control loop, not a full autopilot energy model.

## Turn Limiter Interaction
The bot can change the plane controller's sustain-turn limiter runtime mode.

Principle:

- Below the bot's max-lift turn speed threshold, sustain-turn limiting is enabled to preserve energy.
- Above that independent threshold, sustain-turn limiting can be disabled so the plane may use max-lift turns.
- The max-lift AoA limiter remains part of the plane controller's normal limiter stack.

The threshold is separate from speed-recovery enter/exit speeds. The bot does not change forces to achieve this; it only chooses which pitch-input limiter mode the plane controller should use.

## Follow and Orbit Behavior
When no safety or speed-recovery override is active, the bot flies relative to a target.

Player chase mode:

- Used in singleplayer when a non-bot player plane is found.
- The bot measures target range, target aspect, and closure speed.
- Pursuit guidance chooses lag, pure, or lead pursuit from those measurements.
- The selected pursuit mode creates an aim point relative to the player plane.
- The bot does not orbit the player target.
- The bot commands full throttle unless it is above its max-speed cap.

Approach mode:

- Used for the fallback marker when the marker is outside the orbit band.
- Desired direction points toward the marker.
- If the target has velocity, approach mode can also use pursuit guidance.
- The bot commands full throttle unless it is above its max-speed cap.

Orbit mode:

- Used for the fallback marker when the marker is inside the orbit band.
- The bot computes a radial vector from the target to itself.
- It computes a horizontal tangent from the radial vector and world up.
- Orbit direction chooses clockwise or counterclockwise tangent travel.
- A radial correction term pulls the bot toward the desired orbit radius.
- A vertical correction term nudges the bot toward target altitude.
- The combined direction becomes the desired flight direction.

This is an orbit-like steering behavior, not a physically exact orbital controller.

## Pursuit Modes
Pursuit mode selection is a simple tactical layer used during approach/chase guidance.

The bot measures:

- Range: current distance to the target.
- Closure: positive when the bot is closing range, negative when the target is opening range.
- Aspect: where the bot sits relative to the target's tail.

Lag pursuit:

- Used when the bot is close and either closing fast or not cleanly behind the target.
- The aim point is moved behind the target along the target's travel direction.
- This reduces overshoot pressure and helps the bot settle behind the target.

Pure pursuit:

- Used as the neutral/default mode.
- The aim point is the target's current position.

Lead pursuit:

- Used when the target is opening range or when the bot is far away and not already in a good tail position.
- The aim point is projected ahead of the target using target velocity and a bounded lookahead time.
- This cuts toward where the target is moving instead of chasing its current position.

The pursuit system is not a full intercept solver. It is a practical guidance switch that gives the bot lag/pure/lead behavior without bypassing the flight model.

## Direction-to-Control Mapping
The bot maps a desired world-space direction into aircraft-local controls.

Process:

1. Normalize the desired world direction.
2. Transform it into the plane's local body space.
3. Use local horizontal direction error for roll and yaw.
4. Use local vertical direction error for pitch.
5. Clamp each control input to the plane controller's input range.
6. Submit roll, pitch, yaw, and shared throttle output to the plane controller.

This gives the bot simple steering without bypassing the flight model.

## Control Interface
The bot submits controls through:

```gdscript
set_bot_control_inputs(roll, pitch, yaw, throttle)
```

The plane controller then:

- marks the plane as bot-controlled if needed
- clamps target inputs
- smooths current input channels toward target inputs
- runs the same pitch limiters, torque model, drag model, and aerodynamic force model used by players

The bot sends full throttle while below its max-speed cap and cuts throttle above that cap. Speed and energy behavior are still controlled primarily through pitch guidance and the plane controller's turn limiters.

This keeps bot and player aircraft behavior consistent.

## Networking Implications
Bot state replication uses the existing character replication path.

Authority side:

- Simulates bot controls and physics.
- Emits transform snapshots through the plane controller.
- Relays snapshots to clients through the world spawner.

Client side:

- Does not run `PlaneBotPilot` for remote bots.
- Applies received bot transforms as remote plane state.
- Renders the bot like any other remote aircraft.

The system does not currently replicate bot intent, target state, or deterministic physics inputs. It replicates resulting transform snapshots.

## Current Simplifications
- The bot is reactive and local-rule based, not a strategic AI planner.
- Terrain avoidance is ray-probe based, not navmesh or pathfinding based.
- Orbit steering is approximate.
- Pursuit steering is approximate and does not solve full intercept geometry.
- Speed recovery is a practical controller, not a full aircraft energy management autopilot.
- Multiplayer bots are server-authoritative but remote clients do not predict bot physics.
