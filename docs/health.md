# Health System

## Overview

The health system is a reusable `Node` module (`scripts/health.gd`, `scenes/health.tscn`). It tracks hit points and emits signals when damage is taken and when the owner reaches zero HP. It does not modify its parent node in any way — all behavioural responses (losing control, burning, detargeting) are driven by signal listeners in other scripts.

Any scene that has a child node named `Health` can receive damage via `take_damage(amount)`, which is the same duck-typed entry point used by `missile.gd`'s damage query.

---

## API

### Exports

| Export | Default | Notes |
|---|---|---|
| `max_hp` | 100.0 | Maximum hit points. Also used as the starting value on `_ready`. |

### Properties

| Property | Type | Notes |
|---|---|---|
| `current_hp` | float | Current hit points. Read-only from outside; written only by `take_damage`. |

### Signals

| Signal | Args | When |
|---|---|---|
| `damaged(amount, current_hp)` | float, float | Fired on every `take_damage` call that lands while alive. |
| `shot_down()` | — | Fired exactly once when `current_hp` first reaches 0. |

### Methods

```gdscript
take_damage(amount: float) -> void
```

Subtracts `amount` from `current_hp`, clamps to `[0, max_hp]`, emits `damaged`, and emits `shot_down` if HP just hit zero. A double-kill guard (`_dead` flag) prevents `shot_down` from firing more than once even if `take_damage` is called again after death.

---

## Plane integration

`Health` is a child node of every `PlaneCharacter` (`scenes/plane_character.tscn`). `plane_character_controller.gd` connects to its `shot_down` signal in `_ready` and calls `_on_shot_down()`:

```gdscript
func _on_shot_down() -> void:
    is_shot_down = true
    throttle_input = -1.0
    if flame_trail_scene != null:
        var trail := flame_trail_scene.instantiate() as Node3D
        add_child(trail)
```

`is_shot_down = true` gates the entire control and thrust block in `_physics_process`. The plane loses all propulsion and control authority immediately. Passive physics (gravity, drag, aerodynamic alignment) continue to act on it, so it tumbles and falls under its own momentum.

The flame trail (ported from vimana) is a child `Node3D` with two `GPUParticles3D` — one smoke, one fire. It is attached directly to the plane so it moves with the wreckage.

The plane is **not despawned** on shot-down. It remains in the scene as inert wreckage until a future system decides to clean it up.

---

## Damage delivery

Damage currently comes from missile explosions and ground impacts. `missile.gd`'s `_spawn_explosion` uses a physics shape query to find nearby bodies, then searches each collider and its direct children for a node that `has_method("take_damage")`. `Health` exposes `take_damage`, so it satisfies this check automatically on any plane that carries the node.

Damage falls off linearly with distance inside `explosion_radius`:

```
t = 1 - (dist / explosion_radius)          # 1.0 at ground zero, 0.0 at edge
dmg = lerp(explosion_min_damage, explosion_max_damage, t)
```

A plane at 100 HP requires two or more direct hits to be shot down with default missile values (`explosion_max_damage = 80`).

Ground impacts are handled by `plane_character_controller.gd`. When a locally simulated plane contacts ground geometry above the configured speed threshold, it computes the angle between its movement direction and the contacted surface:

- `0` degrees means the motion is parallel to the surface
- `90` degrees means the motion is directly into the surface

Fast shallow contact can cause proportional damage. Fast steep contact can trigger immediate destruction when both the speed threshold and `ground_impact_fatal_surface_angle_deg` threshold are exceeded.

---

## Targeting interaction

Once a plane has `is_shot_down == true`:

- **`plane_weapon_lock.gd`** refuses to lock it (`_is_lockable` returns false).
- **`plane_bot_pilot.gd`** clears it as a desired weapon target each frame.

The bot pilot also early-returns from its entire `_physics_process` when its **own** plane is shot down, stopping all flight control and weapon activity immediately.

---

## HUD

The telemetry HUD (`plane_telemetry_hud.gd`) reads `current_hp` and `max_hp` directly from the local plane's `Health` child each frame and displays `"current / max"` in the HP row. No signal subscription is needed — polling is sufficient for a display.

---

## Multiplayer

Damage remains server-authoritative in multiplayer:

- Missile explosions call `take_damage()` only on the server-side `Health` instance.
- `world_character_spawner.gd` listens for `damaged` and `shot_down` on each spawned plane and relays health changes to clients with reliable RPCs.
- Remote peers apply the replicated HP to their local `Health` nodes, so HUDs and other readers of `current_hp` stay in sync.
- When a plane is shot down, clients receive a reliable shot-down event, the local `Health` node emits `shot_down`, and `plane_character_controller.gd` runs the same wreckage path everywhere.

Shot-down peers also stop steering: the server rejects any later `sv_submit_input` packets for a dead plane and keeps simulating the wreck itself, and the owning client hands its plane over to snapshot interpolation once `is_shot_down` is set locally.

---

## Tuning

| Parameter | Location | Notes |
|---|---|---|
| `max_hp` | `Health` node export | Set per-prefab. All planes currently default to 100. |
| `explosion_max_damage` | `missile.gd` export | Direct-hit damage at explosion centre. |
| `explosion_min_damage` | `missile.gd` export | Damage at the edge of `explosion_radius`. |
| `explosion_radius` | `missile.gd` export | Radius of the damage query sphere. |
| `ground_impact_damage_speed_threshold` | `plane_character_controller.gd` export | Minimum ground-impact speed that starts applying damage. |
| `ground_impact_fatal_speed_threshold` | `plane_character_controller.gd` export | Minimum ground-impact speed that enables the fatal crash branch. |
| `ground_impact_fatal_surface_angle_deg` | `plane_character_controller.gd` export | Minimum angle between movement direction and ground surface that makes a high-speed crash fatal. |
| `ground_impact_max_damage` | `plane_character_controller.gd` export | Maximum proportional damage from a non-fatal ground impact. |
