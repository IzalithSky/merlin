# Multiplayer Authority Migration Plan (Option B)

Status: implemented — this document is the design contract for the server-authoritative movement model now in place (`sv_submit_input` / server simulation / prediction + reconciliation). See `docs/architecture_review.md` item #1 for review history.

Date: June 12, 2026

## Goal

Replace the client-authoritative movement relay with a server-authoritative simulation:

1. Clients send **input intent** (sequenced control state), never final poses.
2. The server runs the one true flight simulation for **all** planes (players and bots).
3. The server broadcasts authoritative snapshots; clients interpolate remote planes and **predict + reconcile** their own plane (option B: no added input latency).
4. The server owns the flight-model **aero tables**; clients receive them so prediction matches the server simulation.

## Current vs. target data flow

Current (relay):

```text
client A: collect input -> simulate own plane -> submit final pose to server
server:   clamp pose delta -> apply -> rebroadcast to B, C
client B: interpolate A's poses
server:   simulates bots only
```

Target (option B):

```text
client A: collect input -> seq++ -> send input to server
          -> simulate own plane locally (prediction) -> record state per seq
server:   apply A's latest input to A's plane -> simulate all planes
          -> broadcast snapshots (to A: includes ack_seq = last input applied)
client A: compare server state at ack_seq with own recorded state at ack_seq
          -> within tolerance: nothing; beyond: smooth error correction; huge: snap
client B: interpolate A's server snapshots (unchanged path)
```

## Simulation ownership matrix

`_is_simulation_owner()` per plane instance:

| Context | Own plane | Other players' planes | Bot planes |
|---|---|---|---|
| Single player | simulate (local input) | — | simulate (bot pilot) |
| Host (server + player) | simulate (local input) | simulate (net input) | simulate (bot pilot) |
| Pure client | **predict** (local input) | interpolate | interpolate |
| Pure client, own plane shot down | interpolate (handover) | interpolate | interpolate |

Notes:
- On the server every plane is unfrozen and physics-simulated. On clients only the local player's plane simulates (prediction); everything else stays frozen + interpolated, exactly like today.
- When the local plane is shot down on a pure client, prediction stops and the wreck is interpolated from server snapshots. Controls are irrelevant once shot down, so input latency no longer matters, and this avoids fighting the (random, server-rolled) wreck spin impulse. The shot-down spin impulse is applied only by the simulation authority.

## Wire protocol

All RPCs live on `WorldCharacterSpawner` (existing net hub).

### Client → server: input intent

```text
sv_submit_input(input: Dictionary)            # any_peer, call_remote, unreliable_ordered, channel 1
input = {
  "seq": int,        # client physics-tick counter, monotonic
  "roll": float,     # final smoothed control state, [-1, 1]
  "pitch": float,
  "yaw": float,
  "throttle": float,
}
```

- Sent every physics tick by the owning client for its own plane (~60 Hz; ~40 B payload).
- The wire carries the **post-smoothing control state** (what `_collect_inputs` produces), not raw device input. The server does not replicate mouse/assist/decay logic; it clamps each axis to `[-1, 1]` and applies directly. Assists only shape values inside the same envelope any bot already uses via `set_bot_control_inputs`, so accepting the smoothed state is envelope-safe.
- Server validation: sender must own the plane (`get_remote_sender_id()`), plane exists and is not shot down, all values finite, clamped to `[-1, 1]`, `seq` must be newer than the last stored seq (stale/dup packets dropped).
- Replaces `submit_character_state` (deleted, along with `_sanitize_submitted_snapshot` and the `MAX_SUBMITTED_*` clamps — there is no client pose to sanitize anymore).

### Server → clients: authoritative snapshots

```text
apply_character_state(peer_id: int, snapshot: Dictionary)   # authority, call_remote, unreliable_ordered, channel 2 (existing RPC)
snapshot = {
  "tick": int,                 # server snapshot counter per plane (ordering/dedup)
  "position": Vector3,
  "rotation": Quaternion,
  "linear_velocity": Vector3,
  "ack_seq": int,              # player planes only: last input seq integrated into this state
}
```

- Emitted by the server for **every** plane at `network_sync_interval` (~30 Hz), to every world-ready peer **including the owner** (the owner needs `ack_seq` echoes to reconcile). The host's own plane is not echoed to itself.
- Client routing: `peer_id == local` → `apply_authoritative_state()` (reconciliation); otherwise → `apply_remote_state()` (existing interpolation, unchanged).

### Server → client: aero tables

```text
cl_apply_aero_tables(payload: Dictionary)     # authority, reliable
payload = { "lift_table": [...], "drag_table": [...],
            "control_authority_table": [...], "thrust_table": [...] }   # encode_points format
```

- The server captures the effective tables (scene defaults + the server's own `user://plane_aero_tables.json` override, post-sanitize) once at world start and sends them to each peer during `request_world_sync`, before the spawn sync on the same reliable channel.
- Clients store the payload and apply it to every already-spawned and future plane via the existing `set_*_table` setters.
- `_apply_persisted_aero_tables()` (the `user://` load in `PlaneCharacter._ready`) only runs for the simulation authority (single player or server). A client's local table file is ignored in multiplayer — the server defines the flight model.

## Sequence semantics (prediction bookkeeping)

Client tick N (local plane):

1. Top of `_physics_process`: the body state is the integrated result of tick N−1, which used input seq `S(N−1)`. Record `{seq: S(N−1), position, rotation, linear_velocity}` into the prediction history (ring buffer, ~2 s).
2. Fold in any pending reconciliation correction (see below).
3. Collect inputs → increment seq to `S(N)` → emit input intent.
4. Run the flight model (forces applied; physics server integrates after the callback).

Server tick M (same plane):

1. Top of tick: latch `ack = last_applied_seq` **before** consuming a newer input — the current body state was integrated from `ack`.
2. Consume the newest received input (if newer than last applied), set control state, update `last_applied_seq`.
3. Run the flight model.
4. On snapshot emission the body state still corresponds to `ack` (forces from step 3 have not integrated yet), so the snapshot carries `ack_seq = ack`.

Both sides therefore label states identically: “state after integrating the forces computed from input seq X.” The comparison is apples-to-apples.

Known skew: if the server held input X across multiple ticks (packet gap) its state advances extra ticks under X while the client history has exactly one tick per seq. This skew is absorbed by the reconciliation tolerance — it cannot be eliminated without lockstep or rewind-replay.

## Reconciliation (client, own plane)

No rewind/replay: Godot's physics is not deterministic and `RigidBody3D` cannot re-step N frames inside one frame. The standard alternative for non-replayable physics is **error-offset smoothing**:

On receiving an own-plane snapshot with `ack_seq`:

1. Look up the history entry for `ack_seq` (drop all older entries). No entry (startup, just snapped, very late packet) → ignore.
2. `position_error = server.position − history.position` (similarly rotation and velocity).
3. `|position_error| > hard_snap_distance` → teleport to the server state, zero velocity errors, clear history and pending corrections. Covers catastrophic divergence and server-side teleports.
4. Errors within tolerance (`reconcile_position_tolerance`, plus rotation/velocity tolerances) → do nothing. This is the steady state.
5. Otherwise **assign** (not accumulate) the pending correction: `_correction_position = position_error`. Because applied correction is also folded into stored history entries (below), each new ack measures the *remaining* error, so assignment is self-stabilizing.
   Rotation and velocity use a simpler form: on breach, slerp/lerp the current rotation/velocity a fixed fraction toward the server values per received ack. Rotation/velocity divergence is small in practice because both sides run identical models on identical inputs; position is where error visibly accumulates.

Correction folding, every physics tick while a correction is pending:

```text
step = _correction_position * min(reconcile_correction_rate * delta, 1.0)
global_position += step
for entry in prediction_history: entry.position += step
_correction_position -= step
```

The fold shifts both the body and the recorded history so later comparisons stay consistent. Visually this reads as a gentle drift toward the server's truth instead of a snap.

Tuning knobs (exported on `PlaneCharacter`):

| Knob | Default | Meaning |
|---|---|---|
| `reconcile_position_tolerance` | 3.0 m | dead zone before correcting |
| `reconcile_hard_snap_distance` | 60.0 m | beyond this, snap instead of blend |
| `reconcile_correction_rate` | 8.0 /s | exponential fold rate of the error offset |
| `reconcile_rotation_blend` | 0.25 | per-ack slerp fraction toward server rotation on breach |
| `reconcile_velocity_blend` | 0.25 | per-ack lerp fraction toward server velocity on breach |

## Server input handling

- Latest-wins: the server stores at most one pending input per plane (newest seq); each physics tick it applies the pending input if newer than the last applied. Missing packets mean the previous control state is held — for continuous flight controls this is the correct behavior and produces no jerk.
- Player net inputs are applied **directly** (clamped), not run through the bot `move_toward` rate smoothing — the owning client already applied rate/decay smoothing when producing the values; smoothing twice would make server and prediction diverge by construction.
- The input path is a third input mode alongside the two existing ones:

```text
is_bot_controlled            -> _apply_bot_inputs()      (server/single-player bots)
net-controlled (server-side) -> _apply_net_inputs()      (remote players' planes on the server)
otherwise                    -> _collect_inputs()        (local player: host plane, client prediction, single player)
```

## Ground impact authority

- The server simulates everyone, so `_integrate_forces` contact handling on the server covers all planes. `sv_report_ground_impact` (client self-report) is deleted.
- On clients the predicted plane still detects contacts but applies no damage (existing authority gate) and no longer reports. A predicted plane may transiently clip terrain during divergence; the correction pulls it back and the server remains the only damage judge.

## What does not change

- Remote-plane snapshot interpolation (`apply_remote_state`, interpolation delay, extrapolation).
- Weapons: fire request RPCs, server-side cooldown/lock validation, projectile simulation and replication.
- Health replication and shot-down broadcast.
- Lobby flow, world-ready handshake, spawn/despawn/late-join protocol.
- Single-player behavior (no peer: local simulation, local tables, local damage).

## Known limitations (accepted)

1. **Physics non-determinism**: prediction and server sim drift slowly even with identical inputs; the tolerance band plus gentle correction absorbs it. No rewind-replay is possible with `RigidBody3D`.
2. **Held-input skew**: packet gaps make the server integrate a stale input for extra ticks; appears as reconciliation error, handled by the same band.
3. **Displayed-position lag vs. server truth**: hit validation and damage use server state; what the owner sees locally can differ transiently from what others see by up to the correction budget.
4. **Server CPU**: the server now simulates one `RigidBody3D` flight model per player; fine at the intended player counts.

## Implementation steps

1. `docs/mp_plan.md` (this document).
2. **Aero tables**: gate `_apply_persisted_aero_tables` to the authority; payload capture on the server; `cl_apply_aero_tables` RPC; client-side application to current and future planes.
3. **Input intent**: seq counter + per-tick input signal on `PlaneCharacter`; spawner binding for the client's local plane; `sv_submit_input` RPC with validation; net-input mode + ack latch on the server's plane instances.
4. **Server simulation + broadcast**: simulation-owner predicate rework; server binds and rebroadcasts state for all planes (including owner echo with `ack_seq`); delete the relay (`submit_character_state`, sanitize path, pose clamps).
5. **Prediction + reconciliation**: history ring, `apply_authoritative_state`, correction folding, hard snap, shot-down handover to interpolation.
6. **Tests/docs**: mp smokes extended (remote player plane must *move* on the host under server simulation); single-player smokes unchanged; `architecture_review.md` #1 and dev log updated.

## Test plan

- `tests/run_headless_smokes.sh` (all single-player smokes + the 2-peer host/join smoke) passes.
- mp host smoke additionally asserts the client's plane position changes over time on the host (server simulation is actually driving remote players).
- Manual: host + client session; verify client flight feels unchanged (prediction), remote planes smooth, divergence recovers without rubber-banding, shot-down wrecks tumble identically on both screens (single server-rolled impulse).
