# Multiplayer Jitter Investigation

Tool: `NetProbe` static logger (`scripts/net_probe.gd`), writing `user://net_probe_<pid>.log`.
Categories used: `PRED_STATE`, `AUTH_STATE`, `RECON`, `RECON_PHASE`, `INTERP`, `SNAP_ENTITY`, `SNAP_RECV`, `REMOTE_POSE`, `INPUT_RECV`, `INPUT_CONSUME`, `ENV`.

---

## Hypotheses

| ID | Hypothesis | Status |
|----|-----------|--------|
| H1 | Snapshot tick counter wrapping or stalling | Fixed — tick counter was not monotonic; now guarded |
| H2 | Input queue overflow dropping inputs server-side | Fixed — queue max enforced; gap recovery added |
| H3 | Remote interpolation buffer underflow causing freeze-frames | Fixed — buffer seed on connect; min buffer depth enforced |
| H4 | Authoritative snapshot `ack_seq` mislabeled vs. carried body state | Partially fixed — `ack = applied` now, but a per-session systematic offset (±1) remains; adaptive `best_seq` reconciliation compensates (see Finding 1) |
| H5 | Clock skew between client render tick and snapshot tick | Ruled out — `INTERP` probe shows render_tick advances cleanly |
| H6 | Remote interpolation large position jumps (visual jitter on other planes) | Revised — no large jumps in snapshot positions; but uncontrolled plane (no input) produces erratic snapshots (max 221 m/s vel_jump, max 87° heading_delta) causing visual interpolation artifacts. Bot is smoother because AI stabilises it. Camera corrections on the client's own plane also contribute (see Finding 5) |
| H7 | Bandwidth / packet loss causing burst corrections | Ruled out — `SNAP_RECV` shows steady 30 Hz arrival; no burst patterns |
| H8 | Client prediction diverges from server → corrections fire too often | **Partially fixed** — `best_seq` reduces correction rate 21.7% → 12%; velocity correction never fired due to `RECONCILE_VELOCITY_TOLERANCE = 15.0 m/s`, now fixed to 2.0 m/s (see Findings 1–3) |
| H9 | Ownership-specific remote presentation bug for player-driven planes | Ruled out — remote interpolation path is identical for all non-local peers |
| H10 | Physics non-determinism accumulating unbounded | Confirmed as primary remaining divergence source — Y-velocity bias grows monotonically to +4.8 m/s over 20 s, indicating server and client simulations drift unchecked when velocity correction is inactive (see Finding 3) |

---

## Key Findings

### 1. RECON_PHASE: best_seq offset varies per session, adaptive fix works

**Run 1** (253 events, t > 5 s): ack+1 won 53%, ack+0 24%, ack−1 23%. Mean pos_err at each offset monotonically decreased: ack−1 (3.183 m) → ack (2.649 m) → ack+1 (2.263 m).

**Run 2** (974 events, t > 5 s, after fix): ack−1 won 71%, ack+1 20%, ack+0 9%. Offset FLIPPED. Mean pos_err: ack−1 (2.715 m) → ack (4.167 m) → ack+1 (5.717 m).

The direction of the offset is not stable across sessions; the magnitude is large (~1.45 m/step in run 2 vs ~0.4 m/step in run 1). Root cause not fully determined — candidate is whether `WorldCharacterSpawner._physics_process` captures body state before or after the same-tick plane `_physics_process` increments `_net_last_applied_input_seq`.

**Fix applied**: `_probe_reconcile_phase_window` returns `best_seq` (lowest pos_err among ack−1/ack/ack+1); `_reconcile_with_server_state` passes it to `_take_prediction_entry`. This is adaptive and works regardless of which direction the offset falls.

**Result**: correction rate dropped from 21.7% → 12%.

### 2. Correction rate and jitter mechanism

**Run 1** (before fix, 253 events):
- Correction rate: 21.7%, mean pos_err at firing: 3.41 m
- Corrections fire roughly every 5 snapshots (~167 ms) → ~6 Hz camera stutter

**Run 2** (after best_seq fix, 974 events):
- Correction rate: 12%, mean pos_err at firing: 3.078 m (barely above 3.0 m threshold)
- No-correction ceiling: p90 = 2.934 m, max = 2.999 m

Each correction blends `position_error` into `_correction_position`, folded into the plane transform at `reconcile_correction_rate = 8` per second. A 3 m correction produces a visible camera lurch. At 12% rate over 30 Hz snapshots, corrections still fire every ~8 snapshots (~267 ms).

### 3. Velocity correction was dead: RECONCILE_VELOCITY_TOLERANCE = 15.0 m/s

`_reconcile_with_server_state` only applies a velocity correction when `velocity_error.length() > RECONCILE_VELOCITY_TOLERANCE`. The constant was set to 15.0 m/s. The actual Y-velocity bias peaked at 4.8 m/s — it never triggered.

Y-velocity bias over time (run 2, signed mean per 2 s window):

| Time | mean_vy (server − client) |
|------|--------------------------|
| t=4s | −1.854 m/s |
| t=8s | −0.609 m/s |
| t=12s | +0.871 m/s |
| t=20s | +4.166 m/s |
| t=22s | +4.756 m/s (peak) |
| t=36s | +4.800 m/s |

Bias starts negative (client overshoots upward), flips positive around t=10 s, then grows monotonically to ~+4.8 m/s before plateauing. This is unchecked simulation drift: neither velocity nor position correction was closing the gap fast enough. The growing Y error compounded into position error, eventually crossing the 3.0 m threshold and firing corrections, which moved the camera.

**Fix applied**: `RECONCILE_VELOCITY_TOLERANCE` lowered from 15.0 → 2.0 m/s. Velocity correction now fires at every snapshot where `|vel_err| > 2 m/s`, arresting the drift early.

Flight state during peak bias (t=18–26 s): `stab=true pitch_assist=true eff_pitch≈0`, AoA 0–10°. Stabilisation assist computing slightly different corrective forces between server and client (due to diverging attitude state) is the likely driver. AoA is not a strong predictor of Y-velocity bias in this game (planes often inverted; lift primarily contributes to turning, not climb).

### 4. Input pipeline is healthy

- Client seq ahead of server ack: **~23–25 inputs** (~400 ms at 60 Hz); stable across sessions
- No `gap=1` INPUT_CONSUME events at t > 5 s
- No overflow drops; queue depth stays 1–2 entries

### 5. Why the bot looks smooth but the uncontrolled server plane jitters

Both remote planes go through the identical `apply_remote_state` → remote interpolation path. The difference is in snapshot quality:

**SNAP_ENTITY per peer (t > 5 s, run 2):**

| Peer | pos_step mean | vel_jump mean | vel_jump max | heading_delta mean | heading_delta max |
|------|--------------|--------------|-------------|-------------------|------------------|
| 1 (server player, no input) | 3.698 m | 0.601 m/s | **221 m/s** | 0.312° | **87°** |
| 1000000 (bot, AI-controlled) | 4.128 m | 0.512 m/s | 97 m/s | **0.174°** | 87° |

The uncontrolled plane is 1.8× more erratic in heading change per snapshot. Spikes to 221 m/s velocity jump and 87° heading rotation in a single snapshot interval indicate stall/spin events — the plane enters aerodynamic instability with no corrective input. Linear/slerp interpolation cannot recover from an 87° heading discontinuity.

The bot AI applies smooth stabilising inputs every tick, keeping the plane in controlled flight and producing consistent snapshots.

A secondary contribution: the 126 position corrections on the **client's own plane** (mean 3.078 m, 12% rate) move the **camera**, making all nearby planes appear to jump. The server's player plane, typically nearby, suffers more from this camera movement than the distant bot.

**Conclusion**: no-input planes are NOT inherently more predictable — uncontrolled aerodynamics can produce highly erratic states. The fix is either a passive stabilisation fallback on the server for uncontrolled planes, or higher-order (Hermite/cubic) interpolation that handles velocity discontinuities better.

### 6. REMOTE_POSE readback artifact (measurement note)

`_apply_remote_pose` reads `prev_pos = global_position` before writing the new position. On a frozen kinematic `RigidBody3D`, reading `global_position` in `_process` returns the physics server's cached transform from the last physics tick, not the value written in the same render frame. The resulting `pose_delta` values are unreliable (alternating ~68/135/205 m/s pattern at 75 fps vs 60 Hz physics). Visual output is correct; only the measurement is wrong.

---

## Open Questions

1. **Why does the RECON_PHASE best offset flip between sessions?** The offset direction (ack+1 in run 1, ack−1 in run 2) is session-dependent and large in magnitude. A tick-order probe logging spawner and plane `_physics_process` entry timestamps in the same tick would confirm whether spawner captures body state before or after the plane increments the applied seq. `_net_ack_seq` (the pre-consume latch) may be the correct value to use in `build_state_for_batch` rather than `_net_last_applied_input_seq`.

2. **Will RECONCILE_VELOCITY_TOLERANCE = 2.0 m/s cause over-correction?** With `reconcile_velocity_blend = 0.25`, each snapshot applies 25% of the velocity error. At 4.8 m/s bias this corrects 1.2 m/s per snapshot. At 30 Hz, the bias should close in 4–5 snapshots. Need to verify next run doesn't introduce oscillation from over-aggressive velocity blending.

3. **Passive stabilisation for uncontrolled planes.** The server's player plane (no input) spins into unstable states causing snapshot discontinuities. Options: hold-last-attitude autopilot, static-stability trim at zero input, or cubic interpolation with velocity matching on the client side.

---

## Fixes Applied (chronological)

| Fix | File | Change | Effect |
|-----|------|--------|--------|
| `best_seq` reconciliation | `plane_net_adapter.gd` | `_probe_reconcile_phase_window` returns `best_seq`; `_reconcile_with_server_state` uses it for `_take_prediction_entry` | Correction rate 21.7% → 12% |
| `is_bot_peer` client identification | `plane_bot_setup.gd`, `world_character_spawner.gd` | `is_bot_peer` field set via peer_id range check (`>= 1_000_000`) in `configure_plane`; `_is_bot_peer()` left unchanged to avoid affecting `team_id`/`bot_active` | Probe logs now correctly label bot vs player-driven remotes |
| Velocity correction threshold | `plane_net_adapter.gd` | `RECONCILE_VELOCITY_TOLERANCE` 15.0 → 2.0 m/s | Velocity drift now corrected each snapshot; expected to reduce pos_err accumulation and further lower correction rate |

---

## Code Locations

| File | Relevant section |
|------|-----------------|
| `scripts/plane_net_adapter.gd` | `_reconcile_with_server_state` (L420), `_probe_reconcile_phase_window` (L498), `consume_pending_input` (L60), `build_state_for_batch` (L310), `RECONCILE_VELOCITY_TOLERANCE` (L13) |
| `scripts/plane_character_controller.gd` | `_apply_remote_pose`, `_is_simulated_locally`, `_is_predicting_client`, `_is_net_input_driven` |
| `scripts/world_character_spawner.gd` | `_broadcast_world_snapshot`, `_configure_bot_behavior`, `apply_world_snapshot` RPC |
| `scripts/plane_bot_setup.gd` | `configure_plane` — sets `team_id`, `is_bot_peer`, `bot_active` |
