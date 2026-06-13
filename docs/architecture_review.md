# Architecture & Implementation Review

Date: June 11, 2026 — first pass at `2d7200b`; second pass updated against later fixes; third pass June 13, 2026 re-verified everything against `49646ee` (merge of `server_authoritive_movement_1`).
Scope: review of `docs/` and `scripts/` with emphasis on the remaining architecture/process issues that still block the project's stated goal: a stable, testable, server-authoritative baseline.

Method: every open finding was re-checked against the current tree (all three large gameplay scripts read in full, plus the spawner RPC surface, weapons, health, lobby, persistence, tests, and all docs). Fixed items are removed; this document tracks only open work. Finding numbers are historical and stable across passes (gaps are fixed-and-removed items). The resolved authority migration (formerly finding #1, Critical) is documented in `docs/multiplayer.md` (mechanism) and `docs/devlog.md` (implementation passes).

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
| 5 | God objects / mixed responsibilities in controller, bot pilot, and spawner | Architecture | High | Resolved — phases 1–9 landed; remaining shrink is optional follow-on |
| 8 | Documentation discipline | Process | Low | Open — convention is manual, not enforced |
| 15 | Multiplayer lifecycle is untested and incomplete (no respawn; no late-join/disconnect smokes) | Process / Architecture | Medium | Open — new finding this pass |

---

## 5. God objects / mixed responsibilities — High — RESOLVED

**What changed.** The structural split is now complete enough that this is no longer an active architecture finding. The original hot files were reduced and their major secondary responsibilities were extracted into dedicated helpers:

- `plane_character_controller.gd` — **1,222 lines**, down from **1,860**.
- `plane_bot_pilot.gd` — **986 lines**, down from **1,386**.
- `world_character_spawner.gd` — **858 lines**, still under the plan's rough `< 900` close-out target.

**Landings.** The phased split from `tasks/net_protocol_and_god_object_completion_plan.md` produced the following module map:

- `scripts/plane_net_adapter.gd` — prediction, reconciliation, interpolation, snapshot build/apply.
- `scripts/plane_input_collector.gd` — local input collection and smoothing.
- `scripts/health_net_replicator.gd` and `scripts/projectile_net_replicator.gd` — spawner-owned network fan-out helpers.
- `scripts/plane_flight_model.gd` — flight-model, limiter, and Vy logic.
- `scripts/plane_crash_damage_model.gd` — crash / ground-impact damage.
- `scripts/plane_force_debug_adapter.gd` — force debug renderer and force-balance bookkeeping.
- `scripts/plane_bot_engagement_model.gd` — follow-target, collision threat, player acquisition, weapon targeting, and group-cache logic.
- `scripts/plane_bot_debug_adapter.gd` — bot debug renderer / label generation.

**Validation.** `tests/run_headless_smokes.sh` stayed green across the split work, and headless boots of `res://scenes/world_0.tscn` and `res://scenes/bot_duel.tscn` remained clean during the refactor passes.

**Residual stretch, explicitly deferred.** Two files are still above the plan's original rough `~900` line heuristic:

- `plane_character_controller.gd` still owns orchestration plus some aero-table persistence/accessor surface.
- `plane_bot_pilot.gd` still owns the steering / navigation control-law core.

Those are maintainability improvements worth doing if those areas change materially again, but they are no longer blocking the architecture baseline the review was tracking.

---

## 8. Documentation discipline — Low — OPEN

The convention is settled and the current docs comply (status headers on architecture/process docs only; mechanism docs status-free and behavior-focused, pointing at live `@export` values instead of embedding defaults). What remains open is that it is convention, not enforcement — new docs must follow the pattern manually. Cleanup-on-touch work, not a correctness issue.

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

1. **#15 lifecycle** — late-join and disconnect smokes first (they protect everything else), then minimal respawn.
2. **Aero-table load centralization** — move per-plane disk reads to a single world/spawner load path.
3. **Projectile container injection** — remove scene-root path convention from `Autocannon` / `MissileLauncher`.
4. **#8 doc discipline** — keep the status-header convention on new docs; no standing work.
