# Merlin Dev Plan Notes

Status: forward-looking plan only. Historical implementation detail belongs in `docs/devlog.md`; current architecture status belongs in `docs/architecture_review.md`.

Date: May 28, 2026

## Goal

Evolve current multiplayer prototype into a stable, testable, server-authoritative baseline suitable for larger world/flight gameplay.

## Priority Plan

1. Harden movement authority
- Replace client-submitted final transforms with client-submitted input intent.
- Run authoritative movement simulation on server.
- Broadcast server snapshots to all clients.
- Add server validation for rate, speed, and acceleration bounds.
- Tighten the current input-validation envelope beyond finite/ownership/seq checks so impossible sustained motion is rejected explicitly, not just corrected after the fact.

2. Add network smoothing
- Introduce snapshot timestamps or tick IDs.
- Keep small per-remote snapshot buffers on clients.
- Interpolate remote characters with fixed interpolation delay.
- Avoid direct hard-snapping each incoming packet.
- Validate smoothing under synthetic packet loss / latency and retune reconciliation thresholds if remote or own-plane correction still reads as visible jitter.

3. Add reliability policy and packet budget
- Keep spawn/lobby/despawn traffic reliable.
- Keep frequent movement traffic unreliable or unreliable ordered.
- Add fixed network send rate (for example 20-30 Hz).
- Track packet size and send frequency in debug metrics.

4. Stabilize scene transition protocol
- Keep world-ready handshake as requirement before world RPC delivery.
- Add explicit transition states in `Lobby`:
  - Lobby
  - Loading World
  - In World
- Guard all world RPCs by per-peer world state.

5. Improve late-join behavior
- Keep existing players fixed in place when new peer joins.
- Spawn late joiners with configurable radius and conflict checks.
- Optionally add spawn collision avoidance and retry logic.

6. Testing and diagnostics
- Add deterministic multiplayer smoke scripts for:
  - 2-peer host/join
  - 3-peer late join
  - disconnect/reconnect
- Add assertions for:
  - exactly one local-controlled character per peer
  - no world RPC before world-ready
  - no teleport of existing peers on late join
- Add multiplayer validation coverage for prediction/reconciliation edge cases:
  - owner-client shot-down handover
  - sustained-turn correction stability
  - late-join health/spawn-state sync

7. Gameplay expansion baseline
- Replace placeholder cube avatar with aircraft/player rig root.
- Keep movement/network abstraction separated from visuals.
- Add server-side gameplay state channel for future systems:
  - health
  - weapons
  - objectives

## Acceptance Criteria For Next Milestone

1. Host + 2 clients can play for 10 minutes without ownership flips.
2. Late join does not teleport existing players.
3. No RPC path errors for missing world node.
4. Server rejects impossible movement inputs.
5. Remote movement appears smooth under simulated packet loss/latency.

## Implementation Order Recommendation

1. Server-authoritative input pipeline.
2. Snapshot and interpolation layer.
3. Validation and anti-cheat envelope checks.
4. Automated smoke coverage and debug tooling.
5. Gameplay feature integration on top of stable networking base.
