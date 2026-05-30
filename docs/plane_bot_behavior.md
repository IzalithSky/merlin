# Plane Bot Behavior (Current Implementation)

## Scope
This document describes the current plane bot implementation in:

- `res://scripts/plane_bot_pilot.gd`
- `res://scripts/world_character_spawner.gd`
- `res://scripts/plane_character_controller.gd` (bot control interface)

It covers bot spawn/ownership and in-flight control logic.

## Bot Lifecycle and Ownership
### Bot identity
Bots are represented as normal plane characters with reserved peer IDs:

- `BOT_PEER_ID_BASE = 1000000`
- Bot ID = `BOT_PEER_ID_BASE + index`

This lets bots use the same spawn/state replication pipeline as players.

## Spawn configuration
`world_character_spawner.gd` exports:

- `bot_count` (default `1`)
- `bot_spawn_radius` (default `1200.0`)
- `bot_follow_target_path` (default `level/BotFollowTarget`)
- `bot_orbit_range` (default `900.0`)
- `bot_orbit_tolerance` (default `140.0`)

Singleplayer behavior:

- In no-network mode, spawner enforces at least one bot (`bot_count >= 1`).

Multiplayer behavior:

- Server creates bots in `_ready()` via `_spawn_bots(true)`.
- Bot spawn states are inserted into `_peer_spawn_states`.
- Bot spawns are broadcast to connected peers through the same `spawn_character` RPC.

## Who simulates bots
Bots are simulated only on authority side:

- Singleplayer: local instance simulates bot.
- Multiplayer: server simulates bot.
- Clients do not simulate bot flight logic.

In `_configure_bot_behavior(...)`:

- `set_bot_controlled(true)` is only set when `multiplayer == null` or `multiplayer.is_server()`.
- On non-authority peers, any existing `PlaneBotPilot` node is removed.

Result: clients receive bot movement through replicated transform snapshots, not local AI simulation.

## Follow Target Resolution
World spawner resolves a follow target node from `bot_follow_target_path`:

- Default target is `level/BotFollowTarget` in `world_0.tscn`.

When bot pilot is attached, spawner calls:

- `PlaneBotPilot.set_follow_target(target_node)`

Bot pilot also supports a local fallback `follow_target_path` and periodic reacquire, but current flow primarily injects target from spawner.

## Control Interface Between Bot and Plane
Bot does not apply forces directly. It writes control intentions:

- `set_bot_control_inputs(roll, pitch, yaw, throttle)`

Plane controller then smooths bot commands in `_apply_bot_inputs(delta)` using:

- rotation channel ramp = `rot_rate * delta`
- throttle channel ramp = `thr_rate * delta`

That means bot and player share the same downstream flight physics and control response.

## High-Level Flight State Machine
Inside `PlaneBotPilot._physics_process(delta)`:

1. Validate/reacquire follow target.
2. If no target: hold neutral controls with low throttle.
3. Run terrain-avoidance probes.
4. If terrain threat detected: override with escape controls.
5. Else, compute target distance and choose mode (approach outside range band, orbit inside range band).
6. Convert desired world direction into roll/pitch/yaw inputs.
7. Submit controls to plane controller.

## Terrain Avoidance Logic
Bot uses two ray tests through `PhysicsDirectSpaceState3D.intersect_ray()`:

1. Forward probe:
- Direction: velocity direction if moving, otherwise nose forward
- Distance: `max(terrain_probe_min_distance, speed * terrain_prediction_time)`
- If hit:
- Avoid direction = normalized(hit normal + upward bias)
- Apply strong pitch-up and weighted yaw escape

2. Downward probe:
- Cast straight down by `minimum_safe_altitude`
- If hit:
- Build climb direction from `nose_forward + upward boost`

If either probe indicates danger, bot enters terrain escape branch and skips follow/orbit for that tick.

## Follow and Orbit Logic
### Approach mode
Used when outside orbit band (`distance > desired_range + tolerance`):

- Desired direction points toward target.
- Throttle defaults to `approach_throttle_input`.
- If too slow (`speed < minimum_forward_speed`), throttle is forced to `1.0`.

### Orbit mode
Used when near target (`distance <= desired_range + tolerance`):

- Build tangent around target using `up.cross(radial)`.
- Apply `orbit_direction` sign for clockwise/counterclockwise motion.
- Add radial correction term so bot converges toward desired ring radius.
- Add altitude correction term to reduce vertical offset to target.
- Normalize summed direction and fly it.
- Throttle uses `orbit_throttle_input`.
- If bot is too close (`distance < desired_range - tolerance`), use `retreat_throttle_input`.

This is an orbit-like pursuit, not a strict orbital dynamics solver.

## Direction-to-Input Conversion
Given a desired world direction:

1. Transform it into plane local space.
2. Compute control channels:
- roll from local X (`-x * roll_gain`)
- pitch from local Y (`-y * pitch_gain`)
- yaw from local X (`x * yaw_gain`)
3. Clamp each to `[-1, 1]`.

These are command inputs into the same flight controller used by players.

## Networking Implications
- Bot planes emit `local_state_changed` on authority side exactly like local player planes.
- Server relays bot states to clients via existing `apply_character_state` RPC path.
- Clients never own bot control; they only render replicated movement.

This keeps bot behavior deterministic per match host and avoids client-side bot divergence.
