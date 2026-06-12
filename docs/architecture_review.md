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
| 1 | Gameplay still runs on a client-authoritative movement relay | Architecture | Critical | Resolved — server-authoritative simulation with client prediction/reconciliation landed (see `docs/mp_plan.md`) |
| 5 | God objects / mixed responsibilities in controller, bot pilot, and spawner | Architecture | High | Partial — presentation and bot-setup extracted; net seams (input intent, reconciliation, table sync) now explicit, full controller split still open |
| 6 | Stringly-typed cross-script contracts; `class_name` barely used | Implementation | Medium-High | Partial — all core gameplay scripts typed; debug renderers and DisplaySettings typed; remaining duck-typing is intentional |
| 8 | Documentation discipline improved, but not yet consistent across all design docs | Process | Medium | Partial — status headers on architecture/process docs; mechanism docs carry none by convention |

---

## 1. Gameplay built on a client-authoritative relay — Critical — RESOLVED

**What was wrong.** The server was a movement relay: clients simulated their own planes and submitted final transforms; the server only sanitized the worst abuse cases. Clients also controlled their own flight-model tables, and ground-impact damage relied on client self-reporting.

**What landed (June 12, 2026; design in `docs/mp_plan.md`).**
1. Clients send sequenced input intent (`sv_submit_input`: smoothed roll/pitch/yaw/throttle control state) every physics tick; fire paths were already server-validated RPCs.
2. The server runs the one true simulation for all planes — players and bots — injecting net inputs into remote players' planes the same way bot inputs are injected.
3. The server broadcasts snapshots for every plane; clients interpolate remotes (unchanged path) and predict + reconcile their own plane via per-seq prediction history and error-offset smoothing (no rewind/replay — Godot physics is not deterministic).
4. The server owns the aero tables: `user://plane_aero_tables.json` is only read by the simulation authority and distributed to clients during world sync, so client prediction runs the same flight model the server does.
5. Ground-impact damage is observed server-side on the server's own simulation; the client self-report RPC is deleted.
6. Later follow-up fixes tightened prediction parity: own-plane reconciliation now includes angular velocity; the client sends simulation-relevant control-state flags and post-limiter effective pitch so the server no longer simulates remote-player planes with mismatched assist/limiter behavior.
7. Projectile visuals also moved closer to server truth: clients now spawn replica missiles and bullets using the real server simulation paths rather than separate kinematic approximations.

**Residual limitations (accepted, documented in the plan).** Physics non-determinism makes small prediction drift inevitable; the reconciliation tolerance band absorbs it. Held-input skew during packet gaps appears as reconciliation error and is handled the same way.

---

## 5. God objects / mixed responsibilities — High — PARTIAL

**What.** The same three large files still carry too many roles:
- `plane_character_controller.gd`: flight model, input, bot-facing control surface, snapshot emit/apply, interpolation, crash damage, debug rendering, persistence hooks.
- `world_character_spawner.gd`: spawn registry, ownership, movement relay, projectile netcode, cooldowns, health replication, and remaining world-authority coordination.
- `plane_bot_pilot.gd`: bot state machine, target acquisition, avoidance, recovery, and several controller-adjacent math helpers.

**What improved already.**
- Local camera/HUD lifecycle was split into `local_plane_presentation_binding.gd`.
- Bot-pilot creation and setup was split into `plane_bot_setup.gd`.
- Spawn-time configuration is now more explicit, including `PlaneCharacter.configure(...)` before tree entry so controller startup state is deterministic.
- The authority migration (#1) made the net seams explicit inside the existing files: input modes (local / bot / net), prediction + reconciliation, snapshot build/apply, and aero-table sync are now distinct function groups with typed entry points (`apply_net_control_input`, `apply_authoritative_state`, `apply_aero_tables_payload`).

**Why it matters.** The controller and spawner are still large; further feature work keeps adding to the same hot files.

**Fix.** Extract along the now-explicit seams when they next change:
- input collection / smoothing
- authoritative flight model
- snapshot packing / net adapter (prediction history + reconciliation is the natural first extraction)
- projectile networking
- bot decision layer

---

## 6. Stringly-typed contracts — Medium-High — PARTIAL

**What.** Cross-script communication still relies heavily on `get`, `set`, `call`, and `has_method`. The codebase has improved behaviorally, but most important seams are still untyped.

**What improved already.**
- `class_name` now exists on the core gameplay seam scripts, including `PlaneCharacter`, `PlaneBotPilot`, `Health`, `PlaneWeaponLock`, `Autocannon`, and `MissileLauncher`.
- `class_name` also exists on the replicated projectile seam scripts (`Missile`, `Bullet`, `MissileVisual`, `BulletVisual`) so projectile networking paths can cast to concrete types instead of probing ad hoc properties.
- `ForceDebugRenderer3D` and `BotDebugRenderer3D` now have `class_name`; all `.call()` / `.has_method()` calls against them are replaced with direct method calls. (Godot 4 limitation: the type annotation is omitted on the hosting variable because using a `class_name` as a type annotation in a script that also `preload`s the defining file fails to resolve at parse time.)
- `DisplaySettings` is an autoload singleton; `class_name` cannot be added because Godot 4 raises a parse error when a `class_name` matches an autoload name. Assist-setting persistence now accesses the autoload global directly instead of via `get_node_or_null` + string cast.
- `PlaneBotPilot._plane` is now typed as `PlaneCharacter`; `is_in_group("plane_character")` checks replaced with `is PlaneCharacter` / `as PlaneCharacter` casts across the bot pilot and world spawner.
- Assist-setting persistence in `PlaneCharacter` now uses direct typed `DisplaySettings` access; the stringly-typed generic helpers are removed.
- Missile replication in `WorldCharacterSpawner` now casts to `Missile` instead of using `has_signal` / `"target" in node` string guards; client projectile replicas also instantiate concrete `Missile` / `Bullet` nodes instead of bespoke visual approximations.
- Stable plane-child relationships now use direct component accessors instead of ad hoc string lookup in the hot weapon/HUD/camera paths.
- String-based damage dispatch remains intentionally duck-typed where that flexibility is part of the design.

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
- Status headers belong only on architecture and process docs (`dev_plan.md`, `multiplayer.md`, `view_distance.md`, `testing_scenes.md`). Game component docs (`health.md`, `plane_physics_spec.md`, `missiles.md`, `autocannon.md`, `plane_bot_behavior.md`, `fixed_wing_bot_autopilot_summary.md`) describe mechanisms and parameters only — no status header.
- The general discipline is process-dependent rather than enforced convention — new docs need to follow the same pattern manually.

**Fix.**
- Keep the rule that docs describe behavior/invariants, not live defaults, unless the document is specifically about recommended presets.
- Status headers on architecture/process docs only. Mechanism docs have no status line.

This is now cleanup work, not an urgent correctness issue.

---

## Recommended fix order

1. ~~**#1 authority migration**~~ — done; movement is server-simulated from input intent with client prediction (see `docs/mp_plan.md`).
2. **#5 / #6 structural split + typed seams** — extract the now-explicit net/input/flight seams out of the controller and spawner opportunistically as they next change.
3. **#8 doc discipline** — keep status headers on architecture/process docs; mechanism docs stay status-free by convention.
