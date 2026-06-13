# Architecture & Implementation Review

Date: June 11, 2026 — first pass at `2d7200b`; second pass updated against later fixes; third pass June 13, 2026 re-verified everything against `49646ee` (merge of `server_authoritive_movement_1`).
Scope: review of `docs/` and `scripts/` with emphasis on the remaining architecture/process issues that still block the project's stated goal: a stable, testable, server-authoritative baseline.

Method: every open finding was re-checked against the current tree (all three large gameplay scripts read in full, plus the spawner RPC surface, weapons, health, lobby, persistence, tests, and all docs). Fixed items are removed; this document tracks only open work. Finding numbers are historical and stable across passes (gaps are fixed-and-removed items). The resolved authority migration (formerly finding #1, Critical) is documented in `docs/mp_plan.md` (design contract) and `docs/devlog.md` (implementation passes).

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
| 5 | God objects / mixed responsibilities in controller, bot pilot, and spawner | Architecture | High | Open — split plan active; phases 1–4b landed |
| 8 | Documentation discipline | Process | Low | Open — convention is manual, not enforced |
| 14 | Unbatched, string-keyed network protocol; packet budget (dev_plan §3) never implemented | Implementation | Medium-High | Open — new finding this pass |
| 15 | Multiplayer lifecycle is untested and incomplete (no respawn; no late-join/disconnect smokes) | Process / Architecture | Medium | Open — new finding this pass |

---

## 5. God objects / mixed responsibilities — High — OPEN (phases 1–4b done)

**What.** The same three large files still carry too many roles, and all three grew again during the authority migration (third-pass counts):

- `plane_character_controller.gd` — **1,860 lines** (was 1,864 at the second pass): flight model, input collection/smoothing, bot-facing control surface, net-input application, prediction history, reconciliation, remote interpolation, snapshot build, crash damage, sustain-turn/Vy limiter math, debug rendering, aero-table persistence.
- `plane_bot_pilot.gd` — **1,386 lines**: bot state machine, target acquisition, collision avoidance, ground probing, weapon targeting, and controller-adjacent math helpers.
- `world_character_spawner.gd` — **694 lines**: spawn registry, ownership binding, input/state relay RPCs, aero-table distribution, presentation binding.

**Phases 1–4b landed.** `plane_bot_pilot.gd` now delegates its pitch-rate stabilization calls to `PlaneCharacter.get_rate_stabilized_axis_input` / `get_rate_stabilized_input_for_desired_rate`, matching the existing roll delegation and deleting the duplicated control-law helpers. Networking state sync is extracted into `scripts/plane_net_adapter.gd` (**280 lines**), local-player input collection/smoothing is extracted into `scripts/plane_input_collector.gd` (**204 lines**), projectile RPC/cooldown/state replication is extracted into `scripts/projectile_net_replicator.gd` (**289 lines**), and health replication is extracted into `scripts/health_net_replicator.gd` (**88 lines**). `plane_character_controller.gd` and `world_character_spawner.gd` now delegate those responsibilities through helper nodes/scripts. `tests/run_headless_smokes.sh` and headless boots of `res://scenes/world_0.tscn` and `res://scenes/bot_duel.tscn` passed after the refactor.

**Why it matters.** Every multiplayer or flight-model change lands in the same three hot files; review scope and regression risk grow with each feature. The prediction/reconciliation block alone (~250 lines of the controller) is a self-contained module with a clean interface already. The net seams are already explicit (input modes local / bot / net, prediction + reconciliation, snapshot build/apply, aero-table sync each have typed entry points), so extraction is mechanical.

**Fix.** Phased, behavior-preserving split — full plan with module boundaries, moved-function inventory, RPC node-path constraints, and per-phase acceptance criteria in **`tasks/god_object_split_plan.md`**:
1. Delete the duplicated bot-pilot rate-stabilization helpers (delegate to the controller's public versions).
2. `PlaneNetAdapter`: prediction + reconciliation + interpolation + snapshot/seq bookkeeping out of the controller (coordinate with #14 — the wire-format change lands inside this module afterwards).
3. `PlaneInputCollector`: local input collection/smoothing out of the controller.
4. `ProjectileNetReplicator` (and optionally health replication) out of the spawner.
5. Optional stretch: flight-model extraction when that code next changes materially.

---

## 8. Documentation discipline — Low — OPEN

The convention is settled and the current docs comply (status headers on architecture/process docs only; mechanism docs status-free and behavior-focused, pointing at live `@export` values instead of embedding defaults). What remains open is that it is convention, not enforcement — new docs must follow the pattern manually. Cleanup-on-touch work, not a correctness issue.

---

## 14. Unbatched, string-keyed network protocol; no packet budget — Medium-High — NEW

**What.** The authority migration got the *semantics* right but kept a prototype wire format, and `dev_plan.md` §3 ("reliability policy and packet budget … track packet size and send frequency in debug metrics") was never implemented. Three compounding inefficiencies:

1. **O(planes × peers) unbatched packets.** Every plane has its own `_sync_timer` and emits `local_state_changed` independently; `_broadcast_character_state` (`world_character_spawner.gd:603`) then sends one `apply_character_state.rpc_id(...)` per peer. With 8 planes and 3 clients at ~30 Hz that is ~720 separate ENet/UDP packets per second from the server, each paying its own UDP/ENet header, instead of ~90 (one batched world snapshot per peer per tick).
2. **String-keyed Dictionaries as the wire format.** Snapshots serialize the literal key strings `tick / position / rotation / linear_velocity / angular_velocity / ack_seq` (~58 chars plus per-entry Variant overhead) around ~70 bytes of actual state — roughly 3× inflation per packet. Input intent is worse: 13 keys totalling ~200 chars of key text (e.g. `stabilization_assist_enabled`) sent **60 times per second per client** around ~30 bytes of real payload — roughly an order of magnitude of overhead, continuously, on the most frequent message in the game.
3. **Interpolation ignores the tick it already receives.** Remote planes interpolate on `received_at` wall-clock time (`plane_character_controller.gd` `_store_interpolation_snapshot` / `_update_remote_interpolation`); the snapshot `tick` is used only for stale rejection. Network jitter therefore passes straight into remote-plane rendering instead of being absorbed by a tick-based timeline with a fixed interpolation delay (dev_plan §2 is half-done: tick IDs exist but don't drive timing).

**Why it matters.** Correctness is fine on LAN, but bandwidth and packet rate scale as planes × peers, and every new replicated field multiplies the string-key cost. The longer the protocol surface accretes (input flags were just added; more will follow), the more call sites a format change has to touch — this is the classic "cheap now, expensive later" item. It also blocks the dev_plan goal of measuring anything: there are no send-rate/size metrics to even see regressions.

**Fix (best practice, incremental).**
1. Server: accumulate all plane states once per net tick and send **one** snapshot RPC per peer containing all planes (arrays positional, not keyed) — this also centralizes the per-peer world-ready check.
2. Replace Dictionary payloads with positional `Array`s or a `PackedByteArray` via `StreamPeerBuffer`; pack the 8 input booleans into one int bitmask. (Versioning: one leading format byte.)
3. Key remote interpolation off snapshot tick × fixed tick duration with a constant interpolation delay; keep `received_at` only as a fallback.
4. Add the dev_plan §3 debug metrics (bytes/s and packets/s per peer) so the improvement is measurable and future regressions visible.

Best done together with the #5 net-adapter extraction — the same functions are being rewritten either way.

---

## 15. Multiplayer lifecycle untested and incomplete — Medium — NEW

**What.** The riskiest protocol paths have neither tests nor, in one case, an implementation:

- **No respawn or match-end path.** Shot-down is terminal: the wreck persists, the dead client spectates it indefinitely, and the only recovery is leaving the session. `_peer_spawn_states`, cooldown maps, and health replication all assume a plane lives forever. This was flagged as a residual when health replication was fixed and has not moved since.
- **dev_plan §6 multiplayer scenarios are mostly missing.** `tests/run_headless_smokes.sh` exists and the 2-peer host/client smokes are real (the host smoke even asserts server-driven remote movement) — but there is no 3-peer late-join smoke and no disconnect/reconnect smoke. Those are exactly the paths with the most hand-written state (`_register_peer` late-join spawn states, `_world_ready_peers` gating, `_on_peer_disconnected` cleanup, lobby rejection flow) and the least observation.

**Why it matters.** The authority migration multiplied the amount of per-peer server state; every future feature (respawn, scoring, spectating) builds on the join/leave lifecycle. Bugs here are session-killers that single-player testing can never see, and the project's stated bar is a *stable, testable* baseline.

**Fix.**
1. Add a 3-peer late-join smoke (host + client, start game, second client joins in progress with `allow_join_in_progress`, assert spawn states + health sync on all three) and a disconnect smoke (client drops, host asserts despawn + state cleanup; client reconnects if/when supported).
2. Implement a minimal server-authoritative respawn: server despawns the wreck after a delay, reuses `_build_late_join_spawn_state`, and rebroadcasts spawn + full health — all of which already exist as building blocks.

---

## Low / opportunistic notes

- **Per-plane aero-table disk reads.** On the simulation authority every plane's `_ready()` calls `AERO_TABLES_STORE.load_payload()` (a JSON file read) and each plane carries its own copy of the tables; `_capture_server_aero_payload` then re-derives the shared payload from "any server plane". One load at spawner/world level, applied to planes, would remove N file reads per match and make the single source of truth structural rather than conventional.
- **`Autocannon`/`MissileLauncher` locate their projectile container via `get_tree().current_scene.get_node_or_null("projectiles")`** — a path convention coupling weapon components to scene-root layout, with a silent fallback to scene root. Passing the container from the spawner (which already owns `$projectiles`) at configure time would remove the convention.

---

## Recommended fix order

1. **#5 split, phases 1–2 (`tasks/god_object_split_plan.md`)** — duplicate-math deletion, then the `PlaneNetAdapter` extraction; immediately follow with **#14** inside the new module (batch + pack snapshots/inputs, packet metrics). Same code is rewritten either way; doing them back-to-back is cheaper than separately.
2. **#15 lifecycle** — late-join and disconnect smokes first (they protect everything else), then minimal respawn.
3. **#5 phases 3–4** — input collector and spawner split per the plan.
4. **#8 doc discipline** — keep the status-header convention on new docs; no standing work.
