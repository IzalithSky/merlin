# Autocannon

Status: implemented — current runtime behavior for local play and multiplayer authority flow. Live tuning values should be read from the `@export` fields in `scripts/autocannon.gd` and `scripts/bullet.gd`.

## Overview

The autocannon is a short-range, hits-by-contact weapon built from four layers:

1. **Fire control** in `scripts/autocannon.gd`
2. **Authoritative projectile simulation** in `scripts/bullet.gd`
3. **Client-side visual replication** in `scripts/bullet_visual.gd`
4. **Bot fire gating** in `scripts/plane_bot_pilot.gd`

The system is **server authoritative** in multiplayer:

- local players and bots request a shot
- the server decides whether the shot is allowed
- the server spawns and simulates the real bullet
- clients receive visual replicas only

The design assumes **constant-velocity bullets**. Bullet gravity and damping are
disabled in `scenes/bullet.tscn`, and the lead solver in `autocannon.gd`
matches that model.

---

## Principles of Operation

## 1. Firing

`Autocannon` lives as a child node on the firing plane and is reached through stable plane-component accessors rather than string-based lookup.

- **Player fire**: holding `fire_autocannon` calls `_try_fire()` whenever the
  local cooldown reaches zero.
- **Bot fire**: `PlaneBotPilot` calls `autocannon.try_fire()` once its range and
  cone checks pass.
- **Cooldown**: fire rate is limited by `fire_cooldown`; input can be held, but
  rounds only spawn when the cooldown expires.

## 2. Aim direction

If a desired target exists, the cannon computes a lead direction using constant
velocity interception:

- bullet speed is treated as a scalar muzzle speed relative to the shooter
- shooter velocity is subtracted from target velocity to form relative velocity
- the solver finds the future intercept point
- the result is clamped to a forward cone around the shooter nose

If no valid target exists, aim falls back to the plane nose direction.

### Important point about shooter velocity

Shooter velocity is accounted for in the solver through:

- `relative_velocity = target_velocity - plane_velocity`

Then the real launched bullet velocity is:

- `launch_velocity = aim_direction * bullet_speed + plane.linear_velocity`

This is the correct split. The solver should **not** be given a projectile speed
that already includes shooter speed.

## 3. Projectile simulation

The real projectile is `Bullet`, a `RigidBody3D` that:

- stores its launch origin
- travels in a straight line at constant velocity
- despawns after `max_range`
- deals damage on direct body contact
- ignores collision with the shooter

The bullet also spawns a short trail for visibility.

## 4. Multiplayer

In multiplayer:

- clients call `sv_request_fire_autocannon`
- the server validates ownership and server cooldown
- the server spawns the real `Bullet`
- the server sends `cl_spawn_bullet`
- clients simulate `BulletVisual` locally as a straight-line visual-only proxy
- when the real bullet dies, the server sends `cl_despawn_bullet`

## 5. Bot behavior

Bots do **not** aim at the killzone.

- steering uses the target follow/killzone logic
- autocannon fire gating and lead aim use the **actual target position**

That means:

- **pathing** is killzone-based
- **gun gating** is target-based
- **lead solution** is target-based

---

## File Map

| File | Role |
|---|---|
| `scripts/autocannon.gd` | fire control, cooldown, lead solve, local fire path |
| `scripts/bullet.gd` | real bullet simulation and hit processing |
| `scripts/bullet_visual.gd` | client visual-only bullet replica |
| `scenes/bullet.tscn` | real bullet physics body and mesh setup |
| `scenes/bullet_visual.tscn` | visual-only bullet scene |
| `scripts/world_character_spawner.gd` | server fire authority and spawn/despawn replication |
| `scripts/plane_bot_pilot.gd` | bot fire gating |
| `scripts/bot_duel_scene.gd` | duel-scene bot autocannon overrides |
| `scripts/bot_chase_debug_scene.gd` | chase-scene bot autocannon overrides |

---

## `scripts/autocannon.gd`

## Constants

| Name | Meaning |
|---|---|
| `BULLET_SCENE` | Packed scene used for the real locally spawned projectile. |

## Exports

| Export | Default | Meaning |
|---|---|---|
| `bullet_speed` | `1000.0` | Muzzle speed relative to the shooter, in metres per second. Higher values reduce lead and shorten time-to-hit. |
| `fire_cooldown` | `0.125` | Minimum time between rounds, in seconds. Equivalent to `8 rounds/sec`. |
| `lead_cone_half_angle_deg` | `30.0` | Maximum off-nose lead correction. The solver may compute a larger lead, but the result will be clamped to this half-angle. |
| `damage` | `2.0` | Damage value written into each spawned bullet. This is the current source of truth for autocannon damage. |

## Internal state

| Variable | Meaning |
|---|---|
| `_cooldown_remaining` | Time left until the next legal shot. |
| `_projectiles_container` | Scene node used as the parent for spawned bullets. Usually the root `projectiles` node. |

## Functions

### `_process(delta)`

- counts down cooldown
- only accepts player input for the local player
- ignores input if the parent plane is shot down
- fires continuously while `fire_autocannon` is held

### `try_fire()`

Entry point for AI or scripts. Applies the same cooldown and shot-down checks as
the player path, but does not read input.

### `_try_fire(plane)`

Main fire-control function:

1. reads `PlaneWeaponLock.get_desired_target()`
2. computes `aim_direction`
3. routes to either:
   - local fire
   - client RPC request
   - server-authoritative fire
4. resets cooldown

The world/net handoff is resolved by finding the active `world_character_spawner.gd`
authority node, but the cannon/lock relationship itself is now explicit and typed
through the owning `PlaneCharacter`.

### `_fire_local(plane, aim_direction)`

Spawns a real bullet locally and initializes it with:

- shooter reference
- bullet damage
- inherited shooter velocity
- launch position at the plane origin

### `compute_aim_direction(plane, target, projectile_speed, lead_cone_limit_deg)`

Public/static lead solver entry point.

- returns plane nose if no valid target exists
- otherwise solves for constant-velocity interception
- clamps the result into the lead cone

### `_compute_intercept_direction(...)`

Core quadratic solver.

It solves for positive intercept time `t` using the constant-velocity equation:

- `||relative_position + relative_velocity * t|| = projectile_speed * t`

If there is no valid positive solution, it falls back to shooting at the
target’s current position.

### `_clamp_direction_to_cone(nose, raw_direction, lead_cone_limit_deg)`

Limits auto-lead authority so the cannon cannot snap arbitrarily far off-bore.

### `_is_local_player(plane)`

Checks whether the cannon should read local input from this plane.

---

## `scripts/bullet.gd`

## Constants

| Name | Meaning |
|---|---|
| `TRAIL_SCENE` | Packed scene used for the bullet’s trail. |

## Exports

| Export | Default | Meaning |
|---|---|---|
| `max_range` | `2000.0` | Maximum distance from launch origin before despawn. |
| `damage` | `25.0` | Default scene value, but for autocannon shots this is overwritten by `Autocannon.damage` during spawn. |
| `trail_lifespan` | `0.05` | How long live trail segments persist while the bullet is alive. |
| `trail_ttl_after_death` | `0.5` | How long the trail remains after the bullet despawns. |

## Signals

| Signal | Meaning |
|---|---|
| `died(hit, hit_position)` | Emitted when the bullet despawns, whether by hit or by range timeout. |

## Runtime state

| Variable | Meaning |
|---|---|
| `shooter` | Firing plane, used for collision exception. |
| `_origin` | Launch position used for range despawn. |
| `_dead` | Reentrancy guard for despawn. |
| `_trail` | Spawned trail instance. |

## Functions

### `_ready()`

- adds the bullet to the `bullet` group
- records origin
- enables contact handling
- ignores collision with the shooter
- spawns the trail

### `initialize_launch(spawn_position, launch_velocity)`

Launch initializer used after the bullet is inside the tree.

This function exists to ensure:

- the bullet’s actual world-space spawn point is recorded correctly
- the range check uses the real launch point
- the initial orientation matches the true launch velocity

### `_physics_process(_delta)`

- keeps the bullet facing along its velocity
- despawns when `distance_to(_origin) > max_range`
- updates trail position

### `_on_body_entered(body)`

- ignores the shooter
- tries to find a node exposing `take_damage`
- deals damage
- despawns with `hit=true`

### `_find_damage_receiver(node)`

Duck-typed damage lookup:

- if the body itself has `take_damage`, use it
- otherwise check direct children

### `_despawn(hit)`

Stops the trail, emits `died`, then frees the bullet.

### `_spawn_trail()`

Creates the short pink bullet trail.

---

## `scenes/bullet.tscn`

This scene sets the real projectile physics model.

## Physics properties

| Property | Value | Meaning |
|---|---|---|
| `mass` | `0.02` | Lightweight projectile body. |
| `continuous_cd` | `true` | Enables continuous collision detection to reduce tunneling. |
| `gravity_scale` | `0.0` | Disables gravity so the bullet matches the straight-line lead solver. |
| `linear_damp_mode` | `1` | Replace/default-off damping mode. |
| `linear_damp` | `0.0` | Prevents unwanted speed loss from damping. |
| `angular_damp_mode` | `1` | Replace/default-off damping mode. |
| `angular_damp` | `0.0` | Prevents angular damping side effects. |
| `lock_rotation` | `true` | Bullet orientation is driven by script, not by collisions. |
| `contact_monitor` | `true` | Enables hit detection callbacks. |
| `max_contacts_reported` | `1` | One direct contact is enough to despawn the round. |

## Collision shape

| Property | Value | Meaning |
|---|---|---|
| Capsule radius | `0.05` | Effective bullet thickness. |
| Capsule height | `0.3` | Effective hit length. |

## Visual mesh

| Property | Value | Meaning |
|---|---|---|
| Prism size | `Vector3(0.1, 0.6, 0.1)` | Long thin visible round body. |

---

## `scripts/bullet_visual.gd`

This is the client-only straight-line visual counterpart to `Bullet`.

## Constants

| Name | Meaning |
|---|---|
| `TRAIL_SCENE` | Packed scene used for the visual trail. |

## Exports

| Export | Default | Meaning |
|---|---|---|
| `trail_lifespan` | `0.05` | Lifetime of trail segments while visual is alive. |
| `trail_ttl_after_death` | `0.5` | How long the trail lingers after despawn. |

## Runtime state

| Variable | Meaning |
|---|---|
| `_velocity` | Straight-line velocity replicated from the server. |
| `_trail` | Spawned trail instance. |

## Functions

| Function | Meaning |
|---|---|
| `init(pos, vel)` | Initializes replicated spawn position and velocity. |
| `_process(delta)` | Moves the visual in a straight line and keeps it aligned to velocity. |
| `despawn(hit_pos)` | Moves to final position, lets the trail linger, then frees. |
| `_spawn_trail()` | Creates the visual trail. |

---

## Multiplayer hooks in `scripts/world_character_spawner.gd`

## Server-side state

| Name | Meaning |
|---|---|
| `AUTOCANNON_SCRIPT` | Preload used to call the shared lead solver on the server. |
| `_gun_cooldowns` | Per-peer authoritative cooldown timers. |
| `_active_bullets` | Server-owned real bullets by bullet id. |
| `_next_bullet_id` | Monotonic bullet id counter for replication. |
| `_active_bullet_visuals` | Client-side visual replicas by bullet id. |

## Important functions

| Function | Meaning |
|---|---|
| `sv_request_fire_autocannon(firing_peer_id)` | Client-to-server fire request. |
| `_server_fire_autocannon(plane, firing_peer_id)` | Authoritative bullet spawn and replication. |
| `_on_bullet_died(hit, pos, bullet_id)` | Removes authoritative bullet and sends despawn RPC. |
| `cl_spawn_bullet(bullet_id, pos, vel)` | Spawns visual-only bullet on clients. |
| `cl_despawn_bullet(bullet_id, pos)` | Removes client visual at final position. |

---

## Bot parameters

## `scripts/plane_bot_pilot.gd`

| Export | Default | Meaning |
|---|---|---|
| `autocannon_fire_max_range` | `650.0` | Maximum range at which bots are allowed to fire. This is a gate only; it does not affect bullet physics. |

Bots fire only when:

1. a valid target exists
2. target range is within `autocannon_fire_max_range`
3. target angle from the bot nose is within the autocannon’s `lead_cone_half_angle_deg`

## Scene-specific bot overrides

These scenes create bot pilots at runtime and push their own values into the
pilot/cannon:

### `scripts/bot_duel_scene.gd`

| Export | Default | Meaning |
|---|---|---|
| `bot_autocannon_fire_max_range` | `650.0` | Duel-scene bot fire gate range. |
| `bot_autocannon_lead_cone_half_angle_deg` | `30.0` | Duel-scene bot lead cone. |

### `scripts/bot_chase_debug_scene.gd`

| Export | Default | Meaning |
|---|---|---|
| `bot_autocannon_fire_max_range` | `650.0` | Chase-scene bot fire gate range. |
| `bot_autocannon_lead_cone_half_angle_deg` | `30.0` | Chase-scene bot lead cone. |

---

## Tuning Guidance

## Shots consistently fall behind fast crossing targets

- increase `bullet_speed`
- increase `lead_cone_half_angle_deg` if the needed lead is being clamped away

## Shots pass ahead of targets

First verify the projectile model still matches the solver:

- bullet gravity must stay off
- bullet damping must stay off
- client visuals and server bullets must both remain straight-line

If those hold, overlead is usually caused by:

- wrong target velocity source
- too-large lead cone masking bad path geometry
- bots firing while their pursuit geometry is poor, even if range/cone gates pass

## Bots rarely fire

- increase `autocannon_fire_max_range`
- widen `lead_cone_half_angle_deg`
- check whether scene-level bot overrides are replacing your defaults

## Bullets feel weak

Change `Autocannon.damage`, not `Bullet.damage`, if the issue is autocannon
damage tuning. `Bullet.damage` is only the scene default before spawn-time
override.

## Trails are hard to see

Increase:

- `Bullet.trail_lifespan`
- `BulletVisual.trail_lifespan`

or widen the underlying trail widths in `_spawn_trail()`.
