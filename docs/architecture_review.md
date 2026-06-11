# Architecture & Implementation Review

Date: June 11, 2026 — first pass at `2d7200b`, second pass updated against later fixes through the current repo state.
Scope: review of `docs/` and `scripts/` with emphasis on the remaining architecture/process issues that still block the project's stated goal: a stable, testable, server-authoritative baseline.

Method: the original review was re-checked against the current tree, and fixed items were removed so this document now tracks only open work.

## Severity scale

| Level | Meaning |
|---|---|
| Critical | A core feature is broken or the stated architecture goal is structurally undermined; cost of fixing grows with every feature built on top. |
| High | Visible defects or major risk in normal use; fix is well understood. |
| Medium | Erodes maintainability/correctness at the edges; cheap now, expensive later. |
| Low | Worth fixing opportunistically. |

## Summary of open findings

| # | Finding | Type | Severity | Current status |
|---|---|---|---|---|
| 1 | Gameplay still runs on a client-authoritative movement relay | Architecture | Critical | Open — interim hardening landed, authority migration untouched |
| 5 | God objects / mixed responsibilities in controller, bot pilot, and spawner | Architecture | High | Open |
| 6 | Stringly-typed cross-script contracts; `class_name` barely used | Implementation | Medium-High | Open |
| 8 | Documentation discipline improved, but not yet consistent across all design docs | Process | Medium | Partial |

---

## 1. Gameplay built on a client-authoritative relay — Critical — OPEN

**What.** The server is still a movement relay. Clients simulate their own planes and submit final transforms; the server sanitizes the worst abuse cases, but it does not run the true aircraft simulation from input intent.

**What improved already.**
- Server-side fire paths now validate sender identity and shot-down state.
- Server-side autocannon and missile cooldown/lock checks now exist.
- `submit_character_state` now clamps submitted position and velocity deltas before apply/rebroadcast.
- Snapshot interpolation, health replication, and multiplayer smoke coverage now exist.

**What is still wrong.**
- Clients still authoritatively choose their final pose.
- `user://plane_aero_tables.json` remains a client-controlled flight-model input under a client-authoritative movement model.
- Ground-impact damage still depends on client self-reporting for the sender's own crash path.

**Fix (best practice).**
1. Clients send input intent (pitch/yaw/roll/throttle + fire) with sequence numbers.
2. Server runs the one true simulation for all planes.
3. Server broadcasts snapshots; clients interpolate remotes and later predict/reconcile local state.
4. Server owns flight-model tables and envelope validation.

This is still the single most important remaining item.

---

## 5. God objects / mixed responsibilities — High — OPEN

**What.** The same three large files still carry too many roles:
- `plane_character_controller.gd`: flight model, input, bot-facing control surface, snapshot emit/apply, interpolation, crash damage, debug rendering, persistence hooks.
- `world_character_spawner.gd`: spawn registry, ownership, movement relay, projectile netcode, cooldowns, health replication, HUD/camera lifecycle, display settings hooks.
- `plane_bot_pilot.gd`: bot state machine, target acquisition, avoidance, recovery, and several controller-adjacent math helpers.

**Why it matters.** The authority migration in finding `#1` is harder because input, simulation, replication, and presentation seams are still collapsed into the same hot files.

**Fix.** Split along existing seams:
- input collection / smoothing
- authoritative flight model
- snapshot packing / net adapter
- projectile networking
- bot decision layer

Do this in the same phase as the authority migration so the seams are introduced once.

---

## 6. Stringly-typed contracts — Medium-High — OPEN

**What.** Cross-script communication still relies heavily on `get`, `set`, `call`, and `has_method`. The codebase has improved behaviorally, but most important seams are still untyped.

**Why it matters.**
- Renames can fail silently.
- Editor/static tooling cannot help much.
- Large multiplayer paths are harder to reason about because contracts are implicit.

**Fix.**
- Add `class_name` to core gameplay scripts (`PlaneCharacter`, `PlaneBotPilot`, `Health`, `PlaneWeaponLock`, `Autocannon`, projectile visuals/helpers, etc.).
- Replace stringly calls with typed fields/methods where the seam is stable.
- Keep duck-typing only where it is deliberately part of the design (for example `take_damage`).

This is best done alongside the controller/net split in finding `#5`.

---

## 8. Documentation drift — Medium — PARTIAL

**What improved.**
- `docs/missiles.md` now focuses on behavior and points at live `@export` values instead of embedding stale defaults as truth.
- `docs/plane_bot_behavior.md` now reflects that multiplayer bots do in fact run on the server.
- `docs/multiplayer.md` is now clearly a target-design document rather than implied current-state documentation.
- Several feature docs (`health.md`, `autocannon.md`, `testing_scenes.md`) are already in much better shape.

**What is still open.**
- Status headers are not yet universal across all design docs.
- Some docs still mix current behavior, target design, and tuning guidance without clearly labeling which is which.
- The general discipline is still process-dependent rather than enforced convention.

**Fix.**
- Keep the rule that docs describe behavior/invariants, not live defaults, unless the document is specifically about recommended presets.
- Add a one-line status header to every design note:
  - `implemented`
  - `partial`
  - `target design`

This is now cleanup work, not an urgent correctness issue.

---

## Recommended fix order

1. **#1 authority migration** — replace client-authored final poses with input-intent/server-simulated movement.
2. **#5 / #6 structural split + typed seams** — do this alongside the migration so new authority seams are explicit and typed.
3. **#8 broad doc status/header pass** — finish the same documentation discipline across the remaining design notes opportunistically.
