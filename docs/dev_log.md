# Merlin Dev Log

Date: May 28, 2026

## Summary

This project now has a working menu -> lobby -> world loop, dynamic player character spawning, basic multiplayer movement replication, and a migrated world scene with environment assets.

## Completed Work

1. Project setup and world migration
- Migrated `world_0.tscn` terrain/environment content from sibling project.
- Kept level/environment nodes and excluded unrelated world objects.
- Verified skybox + lighting + imported textures/mesh references in Godot 4.

2. Camera and movement prototype
- Added controllable camera behavior with:
  - `WASD` horizontal movement
  - `R/F` vertical movement
  - Mouse yaw + pitch with pitch clamped to +/- 89 degrees
- Normalized movement input vector so diagonal movement is not faster.
- Added inertia using acceleration/deceleration and velocity integration.

3. UI flow
- Added main menu with:
  - New Game (solo)
  - Host Game
  - Join Game
  - Exit
- Added in-game menu with:
  - Restart
  - Main Menu
  - Exit

4. Lobby and session management
- Added `Lobby` autoload singleton to own session state and scene transitions.
- Added lobby stage UI showing players and ready state.
- Added host-controlled `Allow Join In Progress` option.
- Added join rejection path when game already in progress and joining is disabled.

5. Character spawning and visibility
- Decoupled camera from static scene setup.
- Added dynamic player character scene with visible orange marker cube.
- Increased marker cube size and made it opaque.
- Implemented server-driven spawn assignment.

6. Multiplayer world replication
- Added world-level spawner coordinator:
  - Client handshake: `request_world_sync`
  - Server spawn replication: `spawn_character`
  - Server movement relay path
- Added late-join spawn placement around spawn center without teleporting existing players.

7. Ownership and RPC fixes
- Fixed local ownership conflicts where multiple clients could control same character.
- Enforced per-peer local ownership after spawn messages.
- Fixed signal binding for local control events.
- Added world-ready peer gating so server does not send world RPCs to peers still outside world scene.
- Removed RPC path spam (`Node not found: "world"`) by filtering outbound world RPC targets.

8. Warning/error cleanup
- Fixed shadowed variable warnings (`position`, `is_connected`) in GDScript.
- Fixed mouse grab timing warnings by deferring capture and checking focus state.
- Fixed unique ID calls in no-peer mode.

## Current Multiplayer Model

- Transport: `ENetMultiplayerPeer` backend via Godot high-level multiplayer API.
- Topology: host/server with client join.
- Authority model today:
  - Session/lobby is server authoritative.
  - Movement is client-driven with server relay (not fully server-authoritative physics yet).

## Known Gaps

- Server does not yet validate movement envelopes (max speed, acceleration, teleport checks).
- Remote movement smoothing/interpolation is minimal (direct state application).
- No reconciliation/prediction framework yet for secure authoritative movement.

---

Date: May 29, 2026

## Update Summary

Major follow-up work was completed to migrate the flight-style character pipeline and make local presentation deterministic per peer.

## Completed Work (Update)

1. Plane character migration and defaults
- Migrated `jet` behavior into `plane` naming and assets.
- Set world character spawning default to plane type.
- Kept original cube/camera character type available as alternate enum option.

2. Multiplayer spawn/control fixes
- Fixed ownership/control edge cases where peers could end up controlling the wrong character.
- Added roll replication to multiplayer state pipeline (`position + yaw + pitch + roll`).
- Eliminated world transition race causing RPC path failures on `/root/world` by deferring start-game world RPC broadcast until after scene swap.

3. Flight dynamics restoration/tuning
- Preserved Vimana-style speed-based control authority scaling (`speed_factor` based on forward speed and limiter state).
- Restored and tuned directional alignment behavior so aircraft nose aligns toward travel vector (dart-like fall behavior), with torque clamp for stability.
- Tuned control/thrust defaults for the larger placeholder plane body.

4. Camera / UI / character decoupling
- Removed camera from `plane_character` scene and controller.
- Added independent local camera rig scene/script instantiated at runtime.
- Added independent local telemetry HUD scene/script instantiated at runtime.
- Bound camera + HUD dynamically to the local player character on world start and ownership updates.

5. Telemetry HUD
- Added local HUD metrics:
  - Forward-axis airspeed (`dot(linear_velocity, -forward)`).
  - Vertical speed (`linear_velocity.y`).
  - Altitude (`global_position.y`).
- Ensured metrics are local-target derived and not mixed across peers.

6. Verification
- Script parse checks passed for touched scripts.
- Headless scene load checks passed for new camera/HUD scenes and world scene.
- Host/client probes verified:
  - local camera rig targets local peer character
  - local HUD targets local peer character
  - no cross-peer presentation binding

---

Date: May 30, 2026

## Quirky Findings and Root Causes

1. "Why does speed stop at exactly 500 m/s even when net forward force is positive?"
- Root cause: Jolt global velocity limiter.
- Setting: `physics/jolt_physics_3d/limits/max_linear_velocity = 500.0`.
- Effect: plane can report `Net . vhat > 0` while speed stays pinned at 500.
- This is engine-level clamping, not aerodynamic equilibrium.

2. "Drag arrow looks small vs thrust at high speed"
- Root cause: comparing raw vector magnitudes instead of along-velocity contribution.
- Correct interpretation is projection on velocity direction (`.vhat`), not visual length alone.
- Added HUD force-balance readout:
  - `Thrust . vhat`
  - `Drag . vhat`
  - `Gravity . vhat`
  - `Damping . vhat`
  - `Net . vhat`

3. "Camera appears to slide back during acceleration"
- Root cause: camera rig root used positional lerp follow (`follow_lerp_speed = 12`) creating lag under acceleration.
- Fix: camera follow now snaps to target by default (`follow_lerp_speed = 0`), with optional smoothing only if explicitly enabled.
- Also centered camera pitch pivot to aircraft center (removed Y offset).

4. "Hidden resistive terms vs shown forces"
- Earlier debug arrows showed scripted forces but not all engine contributions.
- Added damping force debug arrow using `PhysicsDirectBodyState3D.total_linear_damp`.
- With current setup (`linear_damp_mode = REPLACE`, `linear_damp = 0`) damping is normally zero unless areas contribute.

---

Date: June 11, 2026

## Architecture Review Follow-up

This update records which items from `docs/architecture_review.md` have been completed so far.

## Completed Review Items

1. Item #2: multiplayer health / shot-down replication
- Added reliable server-to-client HP replication for spawned characters.
- Added reliable shot-down replication so every peer updates `is_shot_down` and plays the wreckage path locally.
- Synced health state for late joiners during world sync.
- Kept dead planes broadcasting fall-state transforms so other peers no longer see wrecks freeze in place.

2. Item #3: snapshot protocol
- Changed plane state RPC traffic from plain `unreliable` to `unreliable_ordered`.
- Replaced raw `position + yaw + pitch + roll` packets with snapshot dictionaries carrying:
  - `tick`
  - `position`
  - quaternion `rotation`
  - `linear_velocity`
- Added remote-plane snapshot buffering with interpolation delay and short extrapolation on buffer underrun.
- Remote replicas now reject stale ticks instead of applying late packets out of order.

## Review Status Summary

- Done:
  - #2 Health does not work in multiplayer
  - #3 Snapshot protocol
- Not done yet:
  - #1 Client-authoritative relay architecture
  - #4 Missile replication bandwidth
  - #5 God objects / responsibility split
  - #6 Stringly-typed contracts
  - #7 Multiplayer bot spawning/identity cleanup
  - #8 Broad documentation drift pass
  - #9 Automated smoke tests / test harness
  - #10 Input-layer quirks

## Notes

- Item #2 was completed with the smallest change that makes multiplayer damage function correctly without changing the broader authority model.
- Item #3 improves remote motion quality and packet ordering, but it does not replace the larger server-authoritative movement migration described in item #1.

## Additional Follow-up

3. Item #10: input-layer quirks
- Replaced the hardcoded physical `Ctrl` limiter bypass with a bindable `limiter_override` input action.
- Moved the full default gameplay action set into `project.godot` so actions exist from project boot and are visible in the editor Input Map.
- Changed `KeybindingsSettings` to override events for declared actions instead of manufacturing missing actions at runtime.
- Replaced the always-true `is_hostile_to()` stub with a lightweight `team_id`-based hostility check on plane characters.

## Review Status Summary (Updated)

- Done:
  - #2 Health does not work in multiplayer
  - #3 Snapshot protocol
  - #10 Input-layer quirks
- Not done yet:
  - #1 Client-authoritative relay architecture
  - #4 Missile replication bandwidth

---

Date: June 11, 2026

## Architecture Review Follow-up (Items #11 and #12)

This update records the fixes for the second-pass multiplayer fire-authority and ground-impact findings from `docs/architecture_review.md`.

## Completed Review Items

1. Item #11: server-side autocannon lead state now reaches the server
- Client autocannon fire requests now include `target_peer_id`, matching the existing missile request pattern.
- Server-side autocannon spawning now resolves that peer to a real plane and validates it against the server's own lock envelope before using it for lead aim.
- Replicated planes now expose their latest buffered snapshot velocity through `get_replicated_velocity()`, so server-side lead aim no longer reads zero velocity from remote replicas.
- Bot pursuit / collision checks that depend on remote plane velocity now use the same replicated-velocity accessor instead of the zeroed rigid-body property.
- Server-hosted autocannon fire now keys cooldowns by the plane's actual `peer_id`, avoiding the shared host/bot cooldown slot.

2. Item #12: ground-impact crash angle now uses the real contact normal
- Ground-impact handling now uses `get_contact_local_normal()` as returned by Godot instead of rotating it by the plane basis a second time.
- Retuned `ground_impact_fatal_surface_angle_deg` upward to `25.0` so fatal crash classification remains based on genuinely steep impacts after removing the attitude-dependent normal distortion.

## Review Status Summary (Updated Again)

- Done:
  - #2 Health does not work in multiplayer
  - #3 Snapshot protocol
  - #4 Missile replication bandwidth
  - #9 Tests
  - #10 Input-layer quirks
  - #11 Server-side fire authority reads state that never reaches the server
  - #12 Ground-impact surface normal is double-rotated
- Not done yet:
  - #1 Client-authoritative relay architecture
  - #5 God objects / responsibility split
  - #6 Stringly-typed contracts
  - #7 Multiplayer bot spawning/identity cleanup
  - #8 Broad documentation drift pass
  - #13 `team_id` assignment / HUD friend-foe correctness

3. Item #4: missile replication bandwidth
- Removed per-tick `cl_missile_state` unicast updates from the server missile path.
- Missile spawn RPCs now include the initial launch velocity and locked target peer id.
- Remote peers now run a lightweight local `missile_visual.gd` guidance simulation seeded from spawn data, with authoritative despawn/explosion still coming from the server.
- This reduces missile replication traffic from transform spam every physics tick to spawn/despawn events only for the normal case.

4. Item #9: tests
- Moved the camera-detach harness under `tests/` so it lives with the rest of the smoke coverage.
- Added a two-process host/join multiplayer smoke using `tests/mp_host_smoke.gd` and `tests/mp_client_smoke.gd`.
- The multiplayer smoke asserts both peers load the real world scene, each peer owns exactly one local non-bot plane, and host-side damage on peer 2 replicates back to the client health view.
- Added `tests/run_headless_smokes.sh` as a single runner for the current headless smoke set.

5. Interim multiplayer hardening
- `sv_request_fire_missile` now enforces a server-side missile cooldown keyed by firing peer and validates any named missile target against the firer's server-side lock envelope before homing is granted.
- `submit_character_state` now sanitizes submitted position and velocity deltas before the server applies and rebroadcasts a client snapshot, reducing blind-relay teleport and speed-spike abuse until the input-intent migration lands.

6. Multiplayer bot spawn / identity cleanup
- The server world-ready path now actually calls `_spawn_bots(true)`, so multiplayer sessions spawn bots instead of leaving the documented MP bot path dead.
- Bot identity checks now consult a bot registry populated at spawn time instead of relying on `_is_bot_peer` magic-range arithmetic.

7. HUD team / friend-foe fix
- Bot spawn configuration now assigns bots to team `1` while leaving player aircraft in the default unassigned bucket.
- `is_hostile_to()` now treats unassigned or missing teams as hostile by default, so the targeting HUD no longer renders every contact as friendly.

## Additional June 11 Work

4. Shot-down presentation and control cleanup
- Dead planes now keep sending fall-state snapshots after shot-down so remote peers see wrecks continue falling instead of freezing mid-air.
- Shot-down planes now receive a one-time random roll spin impulse and lose residual angular damping so wrecks tumble more naturally.
- Relative roll clock visibility is now its own display option instead of being tied to the advanced HUD toggle.
- Moved the relative roll clock lower on screen to sit around two-thirds of the way down the viewport instead of at center.

5. Review follow-up fixes from minor notes
- Missile guidance now guards the coincident-target case before dividing by distance, avoiding a one-frame NaN steer path.
- Explosion damage falloff now measures to the closest available collision-shape point instead of always using collider origin distance.
- Vy drag solving now interpolates the AoA crossing for the required lift coefficient instead of snapping to the nearest lift-table sample point.
- Bot collision / target scans now use short-lived cached group lists instead of fresh group queries on every hot path call.

6. Runtime error and warning cleanup
- Targeting HUD now normalizes selected targets through a validated getter before pushing them into `PlaneWeaponLock`, avoiding freed-instance RPC/call errors.
- Bot missile threat checks now skip freed cached missiles before type inspection.
- Renamed remote-state local variables/parameters that shadowed `Node3D.position`, removing parser warnings during script reload.

7. Ground-impact damage and crash-angle tuning
- Planes now take proportional damage on ground contact above a configurable speed threshold.
- High-speed ground impacts now trigger full destruction based on the angle between the plane's movement direction and the contacted ground surface, not the plane's upright tilt.
- `ground_impact_fatal_surface_angle_deg` is documented as `0` degrees for motion parallel to the ground and `90` degrees for motion directly into the ground.
- The default fatal-angle tuning was tightened so avoiding a fatal crash requires the plane to be nearly parallel to the ground at impact.
