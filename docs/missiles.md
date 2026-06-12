# Missiles and Target Locking

Status: partial — implemented and current for runtime behavior; live default values should be read from the `@export` fields in `scripts/missile.gd`, `scripts/missile_launcher.gd`, and `scripts/plane_weapon_lock.gd`.

## Overview

The weapon system has three layers that always run in sequence: **selection**
(camera-space, instant), **lock** (nose-cone + range + timer, automatic), and
**fire** (per-plane launcher). Selection and fire are player/bot inputs; lock is
purely automatic once a target is selected.

---

## Target Selection — `plane_targeting_hud.gd`

Selection is driven by the **camera frame**, not the plane nose, so the player
can select any target in any direction by pointing the camera at it.

| Action | Default key | Effect |
|---|---|---|
| `target_select` | T | Selects the target closest to the screen centre |
| `target_deselect` | G | Clears selection (and therefore lock) |
| `target_cycle_next` | Y | Cycles on-screen targets outward from centre |
| `target_cycle_prev` | — | Cycles inward |

**Nearest-to-centre logic.** `_select_nearest_to_center` projects every
candidate in the `player_character` group onto the viewport, skips any behind
the camera, and picks the one with the smallest squared screen-space distance to
the centre. Selection is sticky: going off-screen does not clear it, and cycling
wraps with `posmod`.

**Off-screen behaviour.** Markers are hidden when `camera.is_position_behind`
is true or when the projected point lies outside the viewport rectangle.
The selection itself is preserved; the marker reappears when the target comes
back on screen.

**Friend/foe colours** (tunable exports on the HUD node):

| Export | Default | Meaning |
|---|---|---|
| `foe_color` | red-orange `(1, 0.25, 0.1)` | Unselected hostile |
| `friend_color` | green `(0.2, 0.9, 0.3)` | Unselected friendly |
| `selected_color` | yellow `(1, 0.85, 0)` | Selected, not yet locked |
| `locked_color` | amber `(1, 0.45, 0)` | Fully locked |

Hostility is determined by calling `is_hostile_to(owner_plane)` on the target.
Any target that lacks that method is treated as hostile.

**Bots** do not use `plane_targeting_hud.gd` at all. Their target is set by the
pilot directly into `PlaneWeaponLock` via `_update_weapon_targeting()`.

---

## Target Lock — `plane_weapon_lock.gd`

Lock is a `Node` child of every plane (`PlaneWeaponLock`). It runs in
`_physics_process` and is completely headless — no rendering, no input.

### How it works

Each frame the node checks three conditions against `_desired_target`:

1. **Validity** — target must be a live, valid instance.
2. **Lockability** — if the target is friendly and `allow_locking_friends` is
   false, lock is refused.
3. **Envelope** — the target must be within `lock_max_range` metres **and**
   within a cone of half-angle `lock_cone_half_angle_deg` around the plane's
   nose (`-z` axis in world space).

While all three pass, `_lock_progress` accrues at `1 / lock_time_sec` per
second and clamps to 1.0. When it reaches 1.0, `_locked` becomes true and
`lock_acquired` fires. The moment any condition fails, progress resets to 0
and `_locked` becomes false immediately — there is no hysteresis on loss.

### Tuning exports

| Export | Default | Effect |
|---|---|---|
| `lock_cone_half_angle_deg` | Half-angle of the nose cone. Wider = easier to acquire but allows off-bore shots. |
| `lock_max_range` | Maximum range at which lock can be acquired or maintained. |
| `lock_time_sec` | Time to go from 0 → full lock while continuously in the envelope. |

### HUD feedback

`plane_targeting_hud.gd` reads back `get_lock_progress()` and `is_locked()`
from the local plane's `PlaneWeaponLock` each frame:

- **No selection** — plain icon in foe/friend colour.
- **Selected, lock progress 0** — icon turns `selected_color`, "SEL" label shown.
- **Selected, lock progress > 0** — lock brackets fade in, percentage shown (e.g. "42%").
- **Fully locked** — icon and brackets turn `locked_color`, "LOCK" label shown.

### Signals

| Signal | When |
|---|---|
| `lock_acquired(target)` | `_lock_progress` reaches 1.0 |
| `lock_lost()` | Lock broken for any reason (target dead, left envelope, selection changed) |

---

## Missile Flight — `missile.gd` / `missile.tscn`

The missile is a `RigidBody3D` that inherits the firing plane's velocity at
launch, then applies constant thrust and guidance. It uses a proportional
navigation variant: the steering direction is `(deviation + Δdeviation).normalized()`,
where `deviation` is the vector to the target and `Δdeviation` is the
frame-over-frame change (a crude lead term). This causes the missile to naturally
lead the target rather than purely tail-chase. The missile always knows its
target's exact position — there is no seeker cone or detection range.

### Flight loop (per physics frame)

1. Apply `thrust` force along `-z` (nose) at full power for the whole flight.
2. Apply quadratic drag: `F_drag = -v * drag_coeff * |v|`.
3. Apply angular stabilisation: damps angular velocity toward zero each frame.
4. Apply guidance (after `proximity_fuse_delay`): compute steer direction, rotate
   nose toward it at up to `max_ang_vel_deg` per second.
5. Detonate if `dist_to_target < proximity_radius`.
6. Die (explode or quiet, per `explode_on_timeout`) if `_time_since_launch >= max_lifetime`.

### Target loss

If the target becomes invalid (plane destroyed, etc.) **after** guidance has
started, the missile flies ballistic for up to `target_loss_grace_period`
seconds. If the target was never set (fired unguided), the missile flies straight
until `max_lifetime`. In both cases, whether it explodes or vanishes quietly is
controlled by `explode_on_timeout`.

### Tuning exports

The current defaults live in `scripts/missile.gd`; this table documents behavior.

| Export | Meaning |
|---|---|
| `thrust` | Constant nose force for the whole flight. |
| `drag_coeff` | Quadratic drag coefficient; lower values raise terminal speed. |
| `lateral_force` | Direct steering force perpendicular to current velocity. |
| `torque_strength` | Angular response strength for guidance and stabilisation. |
| `max_ang_vel_deg` | Hard angular-rate cap for turn authority. |
| `max_lifetime` | Hard kill age regardless of target state. |
| `proximity_radius` | Detonation trigger distance. |
| `proximity_fuse_delay` | Post-launch arming delay. |
| `target_loss_grace_period` | Ballistic grace period after a valid target disappears. |
| `explode_on_timeout` | Chooses explosion versus quiet removal on timeout. |

### Damage exports

| Export | Meaning |
|---|---|
| `explosion_radius` | Radius of the damage query sphere. |
| `explosion_min_damage` | Damage at the edge of the sphere. |
| `explosion_max_damage` | Damage at ground zero. |
| `explosion_collision_mask` | Physics layers scanned for damage receivers. |

Damage delivery uses duck-typing: `receiver.take_damage(amount)` is called only
if the collider or one of its direct children exposes that method. In the
current project, planes with `Health` receive real explosion damage.

### Trail exports

| Export | Meaning |
|---|---|
| `trail_lifespan` | How long each trail segment persists while the missile is alive. |
| `trail_ttl_after_death` | How long the trail lingers after detonation before fading. |

---

## Launcher — `missile_launcher.gd`

One `MissileLauncher` node lives on every plane. It polls player input or
responds to the bot pilot and calls `_try_fire`.

| Export | Meaning |
|---|---|
| `fire_cooldown` | Minimum interval between consecutive shots. |

**Player**: fires on `fire_missile` (default key **F**). If `PlaneWeaponLock`
reports a locked target, the missile is guided; otherwise it flies straight.

**Bot**: `plane_bot_pilot._update_weapon_targeting()` calls `launcher.try_fire()`
the first frame `PlaneWeaponLock.is_locked()` is true. The bot does not have a
separate fire key — locking is sufficient.

The launcher now uses the stable plane-component seam instead of string lookups:

- `PlaneCharacter` exposes direct accessors for its `PlaneWeaponLock` and `MissileLauncher`
- the launcher can ask the owning plane for its current lock state directly
- authority-side spawning is still delegated to `world_character_spawner.gd`

**Multiplayer**: in a networked session, clients send `sv_request_fire_missile`
to the server instead of spawning locally. The server owns all missile
simulation; clients receive spawn/despawn events only, then run a local visual
replica seeded with the spawn transform, launch velocity, and locked target peer
id. See `world_character_spawner.gd` and `missile_visual.gd`.

---

## Tuning Guidance

**Missile can't catch targets at high speed** — raise `thrust` or lower
`drag_coeff`. Check that `lock_max_range` is large enough that lock is achievable
before the missile runs out of fuel (`max_fuel × estimated_missile_speed`).

**Missile overshoots and misses** — raise `proximity_radius` (detonates while
still close) or lower `torque_strength` (reduces guidance oscillation). If the
missile is hunting past the bearing and correcting repeatedly, `torque_strength`
is too high. If it simply flies past at high speed, `proximity_radius` is too
small.

**Lock too easy / too hard** — adjust `lock_cone_half_angle_deg` (cone width)
and `lock_time_sec` (time to acquire). A 15° cone at 4 km range requires the
pilot to hold the nose within ~1 km of the target laterally while closing; wider
cones make BVR shots viable.

**Self-fragging on launch** — increase `proximity_fuse_delay`. Default 0.4 s
gives the missile roughly 64 m of separation at 160 m/s launch speed before the
fuse arms.
