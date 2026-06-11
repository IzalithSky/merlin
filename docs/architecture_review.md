# Architecture & Implementation Review

Date: June 11, 2026 — first pass at `2d7200b`, **second pass at `522e655`** (14 commits later, after the multiplayer-HP, snapshot-protocol, input-quirk, ground-damage, camera, and autocannon work).
Scope: full review of `docs/` and `scripts/` (~36 scripts + 5 test harnesses, ~10,000 lines), scene wiring, and project configuration. Focus: identify the most *ineffective* architecture and implementation decisions, rate their severity, and propose best-practice fixes.

Method: docs were read first, then every claim verified against the code. The second pass re-verified all ten findings line-by-line against HEAD, reviewed the three systems added after the first pass (autocannon/bullets, first-person camera, ground-collision damage), and settled one new finding with a headless physics probe (see #12). Severity reflects impact on the project's own stated goal (dev_plan: "stable, testable, server-authoritative baseline"). Per-finding investigation notes: `tasks/architecture_review_second_pass.md`.

## Severity scale

| Level | Meaning |
|---|---|
| Critical | A core feature is broken or the stated architecture goal is structurally undermined; cost of fixing grows with every feature built on top. |
| High | Visible defects or major risk in normal use; fix is well understood. |
| Medium | Erodes maintainability/correctness at the edges; cheap now, expensive later. |
| Low | Worth fixing opportunistically. |

## Summary of findings

| # | Finding | Type | Severity | Status (2nd pass) |
|---|---|---|---|---|
| 1 | Gameplay built on a client-authoritative relay the project already flagged for replacement | Architecture | Critical | Open — fire paths hardened, movement untouched |
| 2 | Health/damage does not work in multiplayer | Implementation | Critical | **Fixed** (`23cf757`) |
| 3 | Snapshot protocol: hard-snap, plain-unreliable, Euler, no tick IDs/velocity | Implementation | High | **Fixed** (`9e6f7bc`) |
| 4 | Missile state unicast per missile × per peer × every physics tick | Implementation | High | Open — bullet path now proves the fix pattern |
| 5 | God objects: controller (1864), bot pilot (1416), spawner (908) with mixed responsibilities | Architecture | High | Open — all three grew |
| 6 | Stringly-typed cross-script contracts (2/36 scripts use `class_name`) | Implementation | Medium-High | Open — new code continued the pattern |
| 7 | Multiplayer bots: dead code path + identity via magic peer-ID range | Implementation | Medium | Open — new instance added (gun cooldown identity) |
| 8 | Documentation drift: tuning values and behavioral claims contradict the code | Process | Medium | Open — `missiles.md` unchanged; `health.md`/`testing_scenes.md` improved |
| 9 | No automated tests despite an explicit test plan | Process | Medium | Improved — 5 SP harnesses exist; zero MP coverage, no runner |
| 10 | Input-layer quirks: hardcoded cheat key, runtime-only InputMap actions | Implementation | Low | **Fixed** (one regression → #13) |
| 11 | Server-side fire authority reads state that never reaches the server (lead aim dead in MP) | Implementation | High | **New** in second pass |
| 12 | Ground-impact surface normal double-rotated — fatal-crash logic attitude-dependent | Implementation | Medium | **New** in second pass (verified empirically) |
| 13 | `team_id` never assigned — HUD marks every target friendly | Implementation | Low | **New** in second pass |

---

## 1. Gameplay built on a client-authoritative relay — Critical — OPEN

**What.** The server is a blind relay for movement. Each client simulates its own plane and submits final transforms; the server applies and rebroadcasts them with **zero validation**:

- `world_character_spawner.gd:293` — `submit_character_state` (any_peer) applies whatever snapshot the client sends, then rebroadcasts.
- `plane_character_controller.gd:945` — clients emit final position + rotation + velocity ~30 Hz.
- `world_character_spawner.gd:811` — `sv_request_fire_missile` spawns a **server-guided homing missile at any `target_peer_id` the client names**. The server never checks the firer's `PlaneWeaponLock` state, lock envelope, or fire rate — the 1 s missile cooldown lives only on the requesting client (`plane_missile_launcher.gd:60-73`).
- `plane_character_controller.gd:1815` — every plane loads its aero tables from user-writable `user://plane_aero_tables.json` at `_ready`. Under client authority this is a sanctioned flight-model cheat.
- *New since first pass:* `world_character_spawner.gd:577` — `sv_report_ground_impact` lets the client self-report crash damage with unvalidated speed/angle. It can only damage the sender's own plane, so the exploit is omission: a modified client simply never reports and becomes crash-immune. One more system to migrate later.

**Second-pass status.** Direction improved where new code was written: both fire RPCs now verify `get_remote_sender_id()` against the claimed firer and gate on shot-down state, and the **autocannon** got a real server-side cooldown (`_gun_cooldowns`, `world_character_spawner.gd:828-842`) — the first piece of genuinely server-authoritative gameplay. Missiles received none of that, and movement validation remains absent.

**Fix (best practice).** Follow the project's own dev_plan order, it is correct:
1. Clients send *input intent* (pitch/yaw/roll/throttle + fire) at tick rate with sequence numbers.
2. Server runs the one true simulation for all planes (the controller's `set_bot_control_inputs` is a ready-made remote-input entry point).
3. Server broadcasts snapshots; clients interpolate remotes and (later) predict/reconcile the local plane.
4. Server-side envelope checks (speed/accel/teleport bounds, fire-rate, lock validation).
5. Treat `user://plane_aero_tables.json` as a dev-tool input only; in MP the server's tables are authoritative.

Interim cheap win: give missiles the same treatment guns already got (server cooldown + lock-envelope check in `sv_request_fire_missile` — the helper exists in `PlaneWeaponLock._check_lock_envelope`), and clamp movement deltas in `submit_character_state`.

---

## 2. Health does not work in multiplayer — Critical — FIXED (`23cf757`)

**What was broken.** Damage existed only on the server's instances; no HP/shot-down replication of any kind. A "killed" client kept flying with a full-HP HUD; clients never saw bots burn.

**Fix as shipped (verified).** Server-authoritative health now flows to clients exactly along the recommended shape: the spawner binds each plane's `damaged`/`shot_down` signals (`world_character_spawner.gd:496`) and relays reliable `cl_health_changed`/`cl_shot_down` RPCs (`:556`, `:566`); late joiners receive current HP and shot-down state during world sync (`:510`); `Health.apply_current_hp_from_network` / `apply_shot_down_from_network` (`health.gd:26-41`) apply without re-emitting damage loops; every peer plays the wreck path via `apply_remote_shot_down`, and dead planes keep snapshotting so wrecks fall instead of freezing (deliberate, per dev_log). `docs/health.md` gained an accurate Multiplayer section.

**Residual.** No respawn or match-conclusion path: a shot-down player spectates until scene restart. Fine for now; becomes the next missing piece of the gameplay loop.

---

## 3. Snapshot protocol — High — FIXED (`9e6f7bc`)

**What was broken.** Hard-snap on every packet, plain `unreliable` (stale packets applied late), position + Euler payload, no tick/velocity.

**Fix as shipped (verified).** Both state RPCs are `unreliable_ordered` on dedicated channels (`world_character_spawner.gd:293`, `:303`). Snapshots carry `tick, position, quaternion, linear_velocity` (`plane_character_controller.gd:950-956`); receivers reject stale ticks, buffer up to 4 snapshots, render ~100 ms in the past with `lerp`/`slerp`, and extrapolate from velocity on underrun (`:756-776`, `:959-989`). This matches the review's recommended design.

**Residual polish (Low).**
- Interpolation is keyed on *receive time*, not the sender's tick timebase, so network jitter maps 1:1 into render timing. A tick-anchored clock (consume `tick × network_sync_interval`) would smooth it further.
- The snapshot is a Dictionary whose four string keys ship in every packet (~40 B overhead vs. a fixed-order array/`PackedByteArray`). Cheap to change if/when bandwidth is measured (dev_plan §3 wants packet metrics anyway).
- Replicas zero `linear_velocity` every frame (`:992-996`) — correct for frozen visuals, but it erases server-side knowledge of remote velocity, which finding #11 trips over.

---

## 4. Missile replication bandwidth — High — OPEN

**What.** `world_character_spawner.gd:695-712`: every physics tick (60 Hz), the server unicasts a full `Transform3D` (~48 B + headers) per active missile per peer via `cl_missile_state`. No send-rate cap (planes have `network_sync_interval = 0.033`). 8 missiles × 4 clients ≈ 1,920 packets/s of server egress for missiles alone; receivers hard-snap (`missile_visual.gd:36-39`).

**Second-pass note.** The **bullet** system added in `522e655` implements exactly the recommended pattern — spawn/despawn events only, deterministic straight-line client visual (`cl_spawn_bullet`/`cl_despawn_bullet`, `bullet_visual.gd`) — so the idiom is now proven in-repo. Missiles are nearly as deterministic given (spawn transform, velocity, target id); they need only spawn/retarget/detonate events plus rare corrections, or at minimum the planes' 20-30 Hz cadence + interpolation in `missile_visual.gd`.

---

## 5. God objects / mixed responsibilities — High — OPEN, WORSE

**What.** All three monoliths grew since the first pass:
- `plane_character_controller.gd` 1509 → **1864 lines**: flight model + input polling + bot smoothing + limiters/Vy solver + snapshot emit/apply + interpolation + ground-impact damage + debug rendering + aero-table persistence + health listener.
- `world_character_spawner.gd` 680 → **908 lines**: spawn registry + ownership + movement relay + missile netcode + **bullet netcode + gun cooldowns + health replication + ground-impact RPC** + camera/HUD lifecycle + display settings.
- `plane_bot_pilot.gd` 1360 → **1416 lines**, still containing the byte-equivalent duplicate of the controller's rate-stabilization math (`plane_bot_pilot.gd:1156-1190` vs. the public `plane_character_controller.gd:1248-1278`) — inconsistently, since `_get_roll_input_for_error` (`:1127`) already delegates to the plane's public method.

**Why it matters.** `docs/multiplayer.md` prescribes the decomposition (`aircraft_input.gd`, `aircraft_server.gd`, `aircraft_remote.gd`, `aircraft_snapshot.gd`); it was never executed, and every feature since (health relay, snapshots, ground damage, guns) accreted into the same three files. Finding #1's migration is hard *because* input, simulation, and netcode share one class keyed off `is_local_player`/`is_bot_controlled`. In an AI-assisted workflow each edit re-touches a 1,900-line hot file with no MP test net (#9).

**Fix.** Mechanical split along existing seams: `PlaneInput` (device polling/smoothing, same fields bots write), `PlaneFlightModel` (forces/limiters only), `PlaneNetAdapter` (snapshot emit/apply/interpolate), `ProjectileNetManager` (missile + bullet netcode out of the spawner). Delete the bot's duplicated rate-controller in the same pass.

---

## 6. Stringly-typed contracts — Medium-High — OPEN, WORSE

**What.** Still only 2 of 36 scripts declare `class_name` (`visual_trail_3d.gd`, `curve_graph_editor.gd`). Cross-script communication is `node.get("prop")` / `node.call("method")` / `has_method(...)` duck typing throughout; the spawner alone is up to ~63 such sites, and the new autocannon/bullet code continued the pattern (`float(autocannon.get("bullet_speed"))`, `world_character_spawner.gd:771`). The trail-config `set("...")` block is now copy-pasted in **four** scripts (`missile.gd:260`, `missile_visual.gd:10`, `bullet.gd:93`, `bullet_visual.gd:39`).

**Why it matters.** These calls fail *silently*: `set()` on a renamed property is a no-op, `get()` returns `null`, and `null != true` quietly passes. No editor warning, no runtime error — and no autocomplete/static analysis, the cheapest bug-prevention GDScript 2 offers. Finding #11 is partly a child of this: a typed seam between HUD, lock, and server fire path would have made "the server never receives the target" visible at write time.

**Fix.** Add `class_name PlaneCharacter`, `PlaneBotPilot`, `Health`, `PlaneWeaponLock`, `Autocannon`, `Bullet`, `VisualTrailConfig` (or a shared trail-config helper), and replace `get/call/set` with typed access. Keep one documented duck-typed seam (`take_damage`). A few hours of mechanical work; it will surface latent mismatches immediately.

---

## 7. Multiplayer bots: dead code + identity hacks — Medium — OPEN, NEW INSTANCE

**What.**
- `_spawn_bots(broadcast_to_clients)` (`world_character_spawner.gd:102`) — the only multiplayer bot-spawn path — is **still never called** (verified by grep). MP sessions have no bots; `docs/plane_bot_behavior.md:21` ("In multiplayer, the server simulates bots") remains false.
- Bots are identified by a magic peer-ID range (`BOT_PEER_ID_BASE = 1000000`, `_is_bot_peer`, `:185-189`). Godot assigns random int32 peer IDs, so a human can theoretically land in the bot range — entity identity conflated with transport identity.
- *New since first pass, same category error:* the autocannon's server-side fire route passes `multiplayer.get_unique_id()` — always 1 on the server — instead of the plane's `peer_id` (`autocannon.gd:69`), so the host and **all** future server-side bots share a single `_gun_cooldowns` slot. Latent today (no MP bots), real the moment they spawn. Fix: `int(plane.get("peer_id"))`.

**Fix.** Call `_spawn_bots(true)` from the server world-ready path (or delete it until needed); make `_is_bot_peer` consult the spawn registry rather than ID arithmetic; long term (falls out of #1) give bots server-owned entity IDs decoupled from peer IDs.

---

## 8. Documentation drift — Medium — OPEN

**What.** Verified divergences, all still present at HEAD:

| Doc claim (`docs/missiles.md`) | Code reality |
|---|---|
| `torque_strength` default 150 N·m | `10.0` (`missile.gd:6`) |
| `lateral_force` 80,000 N | `60_000.0` (`missile.gd:5`) |
| `proximity_radius` 50 m | `15.0` (`missile.gd:9`) |
| `lock_time_sec` 1.5 s | `0.5` (`plane_weapon_lock.gd:5`) |
| "There is no seeker cone or detection range" | 60° seeker cone that drops the target (`missile.gd:20, 98-101`) |
| "Damage exports (no-op until an HP system exists)… explosion is VFX-only" | HP system exists; explosions deal damage (`missile.gd:149-176`) |

`plane_bot_behavior.md` still documents MP bot simulation that never runs (#7); `multiplayer.md` still reads as current architecture without labeling itself a target design.

**Counter-progress (the process can work):** `health.md` was updated with an accurate Multiplayer section alongside the #2 fix, `autocannon.md` shipped accurate with its feature, `testing_scenes.md` is new and correct, and the dev_log tracks review-item status diligently.

**Fix.** Two rules: (a) docs state *behavior and invariants*, never default numbers — point at the `@export`; (b) every design doc gets a one-line status header: `Status: implemented | partial (what's missing) | target design`. One sitting to apply to `missiles.md`, `plane_bot_behavior.md`, `multiplayer.md`.

---

## 9. Tests — Medium (was Medium-High "empty `tests/`") — IMPROVED, REFRAMED

**What changed.** `tests/` now holds four headless smoke tests (`autocannon_smoke`, `bot_autocannon_smoke`, `chase_autocannon_probe`, `missile_hardpoint_smoke`) and a 9-assertion camera-detach harness (`test_camera_detach.gd`). Real assertions, exit codes, the right shape.

**What's still missing.**
- All five harnesses cover **single-player leaf features**. None of `docs/dev_plan.md` §6's multiplayer smoke scripts (2-peer host/join, late join, disconnect; "exactly one local-controlled character per peer") exist — and findings #2 (first pass) and #11 (this pass) are both exactly the silent-MP-break class those tests would catch. The pattern is now twice-demonstrated.
- No runner: nothing aggregates the five harnesses (`make test` / CI / even a shell script), so they only run when someone remembers them.
- `test_camera_detach.gd` lives in the repo root instead of `tests/`.

**Fix.** Before the authority migration (#1), add one two-process host/join smoke (boot host + client via `OS.create_process --headless`, run 10 s, assert spawn count, single local authority, HP sync, no error spam) and a 10-line runner script over `tests/`. Move the camera harness into `tests/`.

---

## 10. Input-layer quirks — Low — FIXED

All three first-pass items landed: the hardcoded physical-Ctrl bypass is a bindable `limiter_override` action (`plane_character_controller.gd:1489`); all 18 gameplay actions are defined in `project.godot` with `KeybindingsSettings` overriding events instead of manufacturing actions at runtime (`keybindings_settings.gd:142-157` warns on missing actions); the always-true `is_hostile_to` stub was replaced with a `team_id` comparison — which introduced finding #13.

The first pass's four "minor notes" were also all fixed: missile coincident-target NaN guard (`missile.gd:93`), closest-point explosion falloff (`missile.gd:188-257`), interpolated Vy lift-crossing (`plane_character_controller.gd:1698`), cached bot group scans (`plane_bot_pilot.gd:1393`).

---

## 11. Server-side fire authority reads state that never reaches the server — High — NEW

**What.** The autocannon's multiplayer design is the right one — clients request, the server validates, simulates the real bullet, and recomputes lead aim server-side (`docs/autocannon.md`). But both inputs to that server-side aim are dead:

- **The lock target never replicates.** `PlaneWeaponLock` is a purely local node; `set_desired_target` is driven only by the *local player's* targeting HUD (`plane_targeting_hud.gd:110-112`), and `sv_request_fire_autocannon` carries no target argument (`world_character_spawner.gd:829`). On the server, a client plane's weapon lock is permanently empty, so `_server_fire_autocannon` (`:758-773`) computes a null-target aim and **every client shot is an unleaded nose shot**. The lead solver — the feature's core mechanic — silently does nothing for clients; only the host (and single-player) ever benefits.
- **Replica velocity is zeroed.** `_apply_remote_pose` zeroes `linear_velocity` on remote planes every frame (`plane_character_controller.gd:992-996`), so even with a valid target the server computes zero lead against any *client-owned* plane (`compute_aim_direction` reads `target.linear_velocity`, `autocannon.gd:107-109`). The snapshot velocity is received and buffered — then discarded. Server-side bot logic reads the same zeroed property for pursuit lead and threat detection (`plane_bot_pilot.gd:882-883`).

**Why it matters.** This is the same failure class as finding #2 was: split authority where the two halves never meet, breaking silently and only in multiplayer — invisible in single-player testing and to the firing client (who sees tracers either way). It shipped in the same commit cycle that fixed #2, which is the strongest argument yet for the MP smoke test in #9.

**Fix.**
1. Send `target_peer_id` with `sv_request_fire_autocannon` (the missile RPC already does exactly this), resolve it server-side, and validate it against the server's own lock-envelope check (`PlaneWeaponLock._check_lock_envelope` — range + cone — is reusable as-is).
2. Expose the latest buffered snapshot velocity on replicas (e.g. `get_replicated_velocity()` returning `_remote_snapshots.back().linear_velocity`) and use it in `compute_aim_direction` and bot logic instead of the zeroed physics property.

---

## 12. Ground-impact surface normal is double-rotated — Medium — NEW (verified empirically)

**What.** `_handle_ground_impact_contacts` transforms the contact normal by the plane's basis before computing the impact angle (`plane_character_controller.gd:823-824`):

```gdscript
var local_normal := state.get_contact_local_normal(contact_index)
var surface_normal_world := global_transform.basis.orthonormalized() * local_normal
```

But `PhysicsDirectBodyState3D.get_contact_local_normal()` already returns the normal in **world space** — "local" means "on this body" (vs. the collider), not "in local coordinates". Verified with a headless Jolt probe in this project: a sphere rotated (23°, 63°, 46°) resting on a flat floor reports a raw normal of `(0, 1, 0)` (correct), while the basis-multiplied value comes out `(-0.08, 0.64, 0.76)`.

**Consequence.** `_get_surface_impact_angle_deg` and therefore the fatal-crash classification (`ground_impact_fatal_surface_angle_deg`) are corrupted by the plane's own attitude at the moment of contact: a near-parallel skim while rolled can read as a fatal perpendicular impact, and a steep dive can read as shallow. The feature "works" because the fatal-angle tuning (`e872b03`) was calibrated on top of the bug, but its behavior is attitude-dependent noise rather than the documented geometry.

**Fix.** Use the normal as returned (delete the basis multiply), then re-tune `ground_impact_fatal_surface_angle_deg` against the now-correct angle. One line plus a tuning pass; a `tests/` harness dropping a plane at known attitudes would pin it.

---

## 13. `team_id` is never assigned — every HUD target renders friendly — Low — NEW

**What.** The #10 fix replaced the always-hostile `is_hostile_to` stub with a team comparison (`plane_character_controller.gd:1161-1166`), but no code path ever assigns `team_id`; every plane is team 0. The sole consumer — targeting-HUD friend/foe coloring (`plane_targeting_hud.gd:267-268`) — now renders **every** plane with the friendly marker and colors, including bots actively firing on the player. The old stub (everyone hostile) happened to match the all-vs-all reality; the fix inverted the error.

**Fix.** Either assign teams at spawn (e.g. bots team 1 in `_configure_bot_behavior` / the bot scenes) or make the comparison default to hostile while teams are unassigned (`return other.get("team_id") == null or int(...) != team_id` — plus a real team plan when teams matter). Gameplay logic is unaffected either way today (locking/damage ignore hostility), so this is purely about the HUD lying.

---

## Recommended fix order

1. **#11 fire-authority state** — small and self-contained: target id in the fire RPC + server lock-envelope validation + replicated-velocity getter; fix the `peer_id` cooldown key (`autocannon.gd:69`, #7) in the same change. Restores the autocannon's designed MP behavior.
2. **#12 contact normal** — one-line fix + fatal-angle re-tune.
3. **#1 interim hardening** — missile parity with guns (server cooldown + lock check) and movement-delta clamps; then the input-intent migration per dev_plan.
4. **#9 MP smoke test + runner** — before the authority migration, so it has a safety net; the host/join smoke would have caught both #2 and #11.
5. **#5/#6 controller split + `class_name` pass** — alongside the migration (same seams).
6. **#4 missile event-based replication** — port the proven bullet pattern.
7. **#7 MP bots**, **#8 doc status headers + `missiles.md` table**, **#13 teams-or-revert** opportunistically.
