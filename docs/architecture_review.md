# Architecture & Implementation Review

Date: June 11, 2026
Scope: full review of `docs/` and `scripts/` (33 scripts, ~8,000 lines), scene wiring, and project configuration. Focus: identify the most *ineffective* architecture and implementation decisions, rate their severity, and propose best-practice fixes.

Method: docs were read first (`dev_plan.md`, `multiplayer.md`, `plane_physics_spec.md`, `plane_bot_behavior.md`, `missiles.md`, `health.md`, `dev_log.md`), then every claim was verified against the code. Severity reflects impact on the project's own stated goal (dev_plan: "stable, testable, server-authoritative baseline").

## Severity scale

| Level | Meaning |
|---|---|
| Critical | A core feature is broken or the stated architecture goal is structurally undermined; cost of fixing grows with every feature built on top. |
| High | Visible defects or major risk in normal use; fix is well understood. |
| Medium | Erodes maintainability/correctness at the edges; cheap now, expensive later. |
| Low | Worth fixing opportunistically. |

## Summary of findings

| # | Finding | Type | Severity |
|---|---|---|---|
| 1 | Gameplay built on a client-authoritative relay the project already flagged for replacement | Architecture | Critical |
| 2 | Health/damage does not work in multiplayer at all (no HP replication) | Implementation | Critical |
| 3 | Snapshot protocol: hard-snap, plain-unreliable, Euler, no tick IDs/velocity | Implementation | High |
| 4 | Missile state unicast per missile × per peer × every physics tick | Implementation | High |
| 5 | God objects: controller (1509), bot pilot (1360), spawner (680) with mixed responsibilities | Architecture | High |
| 6 | Stringly-typed cross-script contracts (`get`/`call`/`set` everywhere, 2/33 scripts use `class_name`) | Implementation | Medium-High |
| 7 | Multiplayer bots: dead code path + bot identity via magic peer-ID range | Implementation | Medium |
| 8 | Documentation drift: tuning values and behavioral claims contradict the code | Process | Medium |
| 9 | `tests/` is empty despite an explicit test plan and acceptance criteria | Process | Medium-High |
| 10 | Input-layer quirks: hardcoded cheat key, runtime-only InputMap actions | Implementation | Low |

---

## 1. Gameplay built on a client-authoritative relay — Critical

**What.** The server is a blind relay for movement. Each client simulates its own plane and submits final transforms; the server applies and rebroadcasts them with **zero validation**:

- `world_character_spawner.gd:284` — `submit_character_state` (any_peer) applies whatever position/rotation the client sends, then rebroadcasts.
- `plane_character_controller.gd:664` — clients emit raw `position + euler` ~30 Hz.
- `world_character_spawner.gd:622` — `sv_request_fire_missile` spawns a **server-guided homing missile at any `target_peer_id` the client names**. The server never checks the firer's `PlaneWeaponLock` state, lock envelope, or fire rate — the 1 s cooldown lives only on the requesting client (`plane_missile_launcher.gd:42-61`).
- `plane_character_controller.gd:1460` — every plane loads its aero tables from user-writable `user://plane_aero_tables.json` at `_ready`. Under client authority this is a sanctioned flight-model cheat: edit drag/thrust locally and the server relays the impossible result.

**Why it matters.** `docs/multiplayer.md` ("Clients do not authoritatively set their final position", "Server must validate… weapon fire rates") and `docs/dev_plan.md` (priority 1) both define the opposite design, and `docs/dev_log.md` honestly lists the relay as a known gap. The ineffective decision is not the prototype relay itself — it's that **weapons and damage were then built on top of it** (commits `e2526a4` → `232a5a3`) instead of hardening movement first, exactly the trap multiplayer.md warns about ("it avoids rewriting the entire game when multiplayer stops being a toy"). Every gameplay system added now (scoring, objectives, ammo) deepens the eventual rewrite, and finding #2 is the first casualty.

**Fix (best practice).** Follow the project's own dev_plan order, it is correct:
1. Clients send *input intent* (pitch/yaw/roll/throttle + fire) at tick rate with sequence numbers.
2. Server runs the one true simulation for all planes (the controller already has a clean bot-input entry point — `set_bot_control_inputs` — that remote-player input can reuse almost verbatim).
3. Server broadcasts snapshots; clients interpolate remotes and (later) predict/reconcile the local plane.
4. Server-side envelope checks (speed/accel/teleport bounds, fire-rate, lock validation in `sv_request_fire_missile`).
5. Treat `user://plane_aero_tables.json` as a dev-tool input only; in MP sessions the server's tables must be authoritative (replicate table hash on join, reject mismatches).

Interim cheap win if full authority is deferred: validate fire rate + lock envelope server-side and clamp movement deltas — both are <50 lines in `world_character_spawner.gd`.

---

## 2. Health does not work in multiplayer — Critical (silent feature break)

**What.** Damage exists only on the server's instances. There is no RPC, synchronizer, or any other mechanism replicating `current_hp`, `damaged`, or `shot_down` (verified: zero network references in `health.gd`, and no HP-related RPCs anywhere). Consequences in a networked session:

- Missiles simulate server-side and call `take_damage()` on the **server's replica** of a client's plane (`missile.gd:168-172`, `health.gd:16`).
- The owning client's own plane never hears about it: its HUD shows full HP forever (`plane_telemetry_hud.gd:84` polls the *local* Health node), `is_shot_down` stays false, it keeps flying and submitting transforms — and the server keeps relaying them (`submit_character_state` has no shot-down gate). A "killed" player is effectively immortal.
- Client-side replicas of server bots never get `is_shot_down = true` either, so clients never see the flame trail (`plane_character_controller.gd:625` runs only where the signal fired — the server), and a client's `PlaneWeaponLock` will happily lock wreckage (`plane_weapon_lock.gd:97` reads the stale local replica).

`docs/health.md` never mentions multiplayer — the HP system (commit `232a5a3`) was designed single-player and bolted onto a networked game without extending the net layer. This is the concrete cost of finding #1's mixed authority model: movement is client-authoritative, damage is server-authoritative, and the two halves never meet.

**Fix.** Make damage state flow server → clients:
- Server applies damage (already true), then sends a reliable `cl_health_changed(peer_id, current_hp)` and `cl_shot_down(peer_id)` RPC (or attach a `MultiplayerSynchronizer` to `Health` — it is exactly the "simple property replication" case the docs recommend it for).
- On `cl_shot_down`, every instance sets `is_shot_down`, spawns the flame trail, and the server stops relaying that peer's `submit_character_state`.
- Add a respawn/despawn decision so MP matches can actually conclude.

---

## 3. Snapshot protocol — High

**What.** `plane_character_controller.gd:595` `apply_remote_state` hard-snaps `global_position`/`rotation` on every packet and zeroes velocities. The snapshot itself (`_emit_local_state`, line 664) is `position + 3 Euler angles`: no tick ID, no timestamp, no velocity. Both RPC legs are plain `unreliable` (`world_character_spawner.gd:284, 294`) — **not** `unreliable_ordered` — so stale packets that arrive late are applied, making remote planes jump backward under jitter.

**Why it matters.** Remote aircraft motion is the single most visible thing in a flight MP game. The project's own `multiplayer.md` prescribes `unreliable_ordered` for homogeneous transform streams and lists "tick IDs, velocity, interpolation delay" as the reason to use custom snapshots — the custom snapshot was built but carries none of those fields. Euler angles also gimbal-degenerate at pitch ±90°, a state aerobatic planes visit constantly; quaternions are the standard for attitude replication.

**Fix.** Dev_plan priority 2, plus:
- Change both state RPCs to `"unreliable_ordered"` (one-line change each) — immediate improvement.
- Snapshot payload: `tick, position, quaternion (4×f32 or smallest-three), linear_velocity` (~40 bytes).
- Client keeps a 2-3 snapshot buffer per remote plane and renders ~100 ms in the past with `lerp` + `slerp`; extrapolate from velocity when the buffer underruns. Unfreeze nothing — replicas can stay frozen kinematic visuals.

---

## 4. Missile replication bandwidth — High

**What.** `world_character_spawner.gd:571-582`: every physics tick (60 Hz), the server unicasts a full `Transform3D` (12 floats ≈ 48 B + headers) per active missile per peer via `cl_missile_state`. There is no send-rate cap (planes at least have `network_sync_interval = 0.033`). 8 missiles × 4 clients = ~1,920 packets/s of server egress for missiles alone; receivers hard-snap them (`missile_visual.gd:36`).

**Fix.** Either of:
- Apply the same snapshot cadence as planes (15-20 Hz) + client-side interpolation in `missile_visual.gd` (it already has `_process`; lerp toward the last received transform), payload as `position + quaternion`.
- Better: missiles are deterministic given (spawn transform, velocity, target id, seed) — spawn them client-side as dumb simulations and send only spawn/retarget/detonate events, with rare corrections. This is the standard projectile pattern and reduces steady-state traffic to ~zero.

---

## 5. God objects / mixed responsibilities — High (maintainability)

**What.**
- `plane_character_controller.gd` (1509 lines) is simultaneously: flight-force model, input device polling (`Input.get_action_strength` at line 314+), bot-input smoothing, two pitch limiters + Vy solver, network snapshot emitter, remote-state applier, debug-force renderer manager, aero-table store loader, and health listener.
- `world_character_spawner.gd` (680) is: spawn registry, ownership enforcer, movement relay, missile netcode, camera/HUD lifecycle, and display-settings applier.
- `plane_bot_pilot.gd` (1360) is: FSM, steering, sensors, weapon control, debug renderer — and contains a **byte-for-byte duplicate** of the controller's rate-damping math (`_get_rate_stabilized_axis_input` at `plane_bot_pilot.gd:1148` vs the public `get_rate_stabilized_axis_input` at `plane_character_controller.gd:906`; same for the desired-rate variant).

**Why it matters.** `docs/multiplayer.md` itself prescribes the decomposition (`aircraft_input.gd`, `aircraft_server.gd`, `aircraft_remote.gd`, `aircraft_snapshot.gd`) — it was never executed. Concretely: finding #1's fix (server-side simulation of remote players' inputs) is hard *because* input polling, simulation, and netcode live in one class keyed off `is_local_player`/`is_bot_controlled` flags. Every new feature (shot-down gating, relative roll, Vy) added more flag-guarded branches to `_physics_process`. In an AI-assisted workflow (per README) monoliths are extra risky: each edit re-reads and re-touches a 1,500-line hot file with no test net (finding #9).

**Fix.** Mechanical, low-risk split along the seams that already exist:
- `PlaneInput` node: device polling + smoothing → writes the same `roll/pitch/yaw/throttle_input` fields (bots already write through `set_bot_control_inputs`; players should go through the identical interface).
- `PlaneFlightModel` (the RigidBody3D script): forces, torques, limiters only.
- `PlaneNetAdapter` node: snapshot emit/apply (then #3 lives in one place).
- Move missile netcode out of the spawner into a `ProjectileNetManager`.
- Delete the bot's duplicated rate-controller; call the plane's public one (it already does at other call sites).

---

## 6. Stringly-typed contracts — Medium-High

**What.** Only 2 of 33 scripts declare `class_name` (`visual_trail_3d.gd`, `curve_graph_editor.gd`). Cross-script communication is overwhelmingly `node.get("prop")`, `node.call("method")`, `node.set("prop", v)`, `has_method(...)` duck typing: e.g. `world_character_spawner.gd:168` (`pilot_node.set("killzone_distance", …)`), `plane_bot_pilot.gd:151` (`_plane.get("is_shot_down") == true`), `plane_weapon_lock.gd:97`, `plane_telemetry_hud.gd:84`, `plane_missile_launcher.gd:52`, the whole trail-config block duplicated in `missile.gd:184` and `missile_visual.gd:10`.

**Why it matters.** These calls fail *silently*: `set()` on a renamed property is a no-op, `get()` returns `null` and `null != true` quietly passes. A typo or rename produces no editor warning, no runtime error — just a bot that stops detargeting dead planes. It also defeats autocomplete and the static analyzer, which is the cheapest bug-prevention tool GDScript 2 offers.

**Fix.** Add `class_name PlaneCharacter`, `class_name PlaneBotPilot`, `class_name Health`, `class_name PlaneWeaponLock`, etc., and replace `get/call/set` with typed member access (`var plane: PlaneCharacter = …; plane.is_shot_down`). Where genuine polymorphism is wanted (damage receivers), keep one documented duck-typed seam (`take_damage`) and type everything else. This is a few hours of mechanical work and immediately surfaces latent mismatches.

---

## 7. Multiplayer bots: dead code + identity hack — Medium

**What.**
- `_spawn_bots(broadcast_to_clients)` (`world_character_spawner.gd:95`) — the only multiplayer bot-spawn path, complete with client broadcast — is **never called** (verified by grep). Bots only spawn in the `multiplayer_peer == null` branch. So `docs/plane_bot_behavior.md`'s "In multiplayer, the server simulates bots" is currently false: MP sessions have no bots, and the code that would add them is silently rotting.
- Bots are identified by a magic peer-ID range: `BOT_PEER_ID_BASE = 1000000` (`world_character_spawner.gd:14`, `_is_bot_peer:178`). Godot 4 assigns *random* int32 peer IDs to clients, so a human peer can land inside `[1000000, 1000000 + bot_count)` and be misclassified (bot pilot attached, ownership broken). Probability is tiny per join, but it's a category error — entity identity conflated with transport identity — and it also breaks if `bot_count` changes between sessions.

**Fix.** Short term: call `_spawn_bots(true)` from the server world-ready path (or delete it until needed), and make `_is_bot_peer` consult the actual `_peer_spawn_states` bot registry rather than arithmetic on the ID. Long term (falls out of #1): spawn bots as server-owned entities with their own entity IDs, decoupled from peer IDs.

---

## 8. Documentation drift — Medium

**What.** The docs are unusually good for a prototype — and several are wrong, which is worse than absent because they invite decisions on stale data. Verified divergences:

| Doc claim (`docs/missiles.md`) | Code reality |
|---|---|
| `torque_strength` default 150 N·m | `10.0` (`missile.gd:6`) |
| `lateral_force` 80,000 N | `60_000.0` (`missile.gd:5`) |
| `proximity_radius` 50 m | `15.0` (`missile.gd:9`) |
| `lock_time_sec` 1.5 s | `0.5` (`plane_weapon_lock.gd:5`) |
| "There is no seeker cone or detection range" | 60° seeker cone that drops the target (`missile.gd:20, 94-97`) |
| "Damage exports (no-op until an HP system exists)… explosion is VFX-only" | HP system exists; same doc set (`health.md`) documents it |

Also `plane_bot_behavior.md` documents MP bot simulation that never runs (#7), and `multiplayer.md` describes the architecture the code doesn't have (#1) without labeling itself aspirational.

**Fix.** Adopt two rules: (a) docs state *behavior and invariants*, never default numbers — point at the `@export` for values (they have exactly one source of truth in the scene/script); (b) every design doc gets a one-line status header: `Status: implemented | partial (what's missing) | target design`. The dev_log already does this well; the system docs should match.

---

## 9. Empty `tests/` directory — Medium-High

**What.** `tests/` exists and contains nothing. `docs/dev_plan.md` §6 specifies deterministic multiplayer smoke scripts and concrete assertions ("exactly one local-controlled character per peer", "no world RPC before world-ready", "no teleport on late join"), and lists five acceptance criteria — none are executable. Findings #2 and #7 are exactly the class of regression (feature silently broken in a mode nobody manually replayed) that the planned smoke tests would have caught, and an AI-assisted workflow raises the regression rate on untested paths.

**Fix.** Don't start with a framework debate; start with the dev_plan's own list as headless scripts (the engine binary and headless smoke-test recipe are already known-good for this repo):
1. A `SceneTree` script that boots two instances (host + client via `OS.create_process` with `--headless`), runs 10 s, and asserts spawn count, single local authority, and no error spam.
2. A single-process physics test: spawn a `plane_character.tscn`, drive fixed inputs N ticks, assert speed/AoA envelopes — protects the flight model and limiters during tuning.
3. A health test: missile explosion → `take_damage` → `shot_down` fires once.
Wire them into a `make test` / CI step. gdUnit4 or GUT can come later; the harness matters less than existence.

---

## 10. Input-layer quirks — Low

- `plane_character_controller.gd:1147` — holding **physical Ctrl** disables the sustain-turn limiter via hardcoded `Input.is_key_pressed(KEY_CTRL)`, bypassing the entire `KeybindingsSettings` system (not rebindable, not discoverable, active in MP). Make it a bindable action (`limiter_override`) like the other 15 actions, or remove it.
- Input actions are split-brained: 2 defined in `project.godot`, 13 created at runtime by the `KeybindingsSettings` autoload (`keybindings_settings.gd:130`). The editor's Input Map UI can't see most actions, and any code running before that autoload errors on unknown actions. Define all actions in `project.godot` as the defaults; let the autoload only *override* events.
- `is_hostile_to` is a stub returning true for every valid node (`plane_character_controller.gd:831`), so the targeting HUD's friend/foe coloring and `allow_locking_friends` are dead features. Either implement a team field or delete the friend-path until teams exist.

### Minor notes (no action required now)

- `missile.gd:95` divides by `dist` before the zero check (`dist < proximity_radius` comes after) — coincident target ⇒ NaN steering for one frame.
- Explosion damage measures distance to the collider *origin*, not closest point (`missile.gd:169`) — fine at 50 m radius vs plane size, will bite with bigger hulls.
- Vy solver picks the nearest lift-table *point* rather than interpolating the crossing (`plane_character_controller.gd:1356`) — coarse but self-consistent.
- Per-tick `get_nodes_in_group` scans (bot threat scan: planes + missiles per bot per tick, `plane_bot_pilot.gd:810`) are fine at current entity counts; revisit past ~20 entities.

---

## Recommended fix order

1. **#2 HP replication** — small, self-contained, makes the existing MP game actually function. Also add the shot-down relay gate.
2. **#3 quick wins** — `unreliable_ordered` (2 lines) now; snapshot+interpolation as its own task.
3. **#1 server authority for fire + movement envelope validation** — server-side cooldown/lock check in `sv_request_fire_missile` first (cheap), then the input-intent migration per dev_plan.
4. **#9 smoke tests** — before the authority migration, so the migration has a safety net.
5. **#5/#6 controller split + `class_name` pass** — do alongside the authority migration since it touches the same seams.
6. **#4 missile event-based replication**, **#7 MP bots**, **#8 doc status headers**, **#10** opportunistically.
