# Devlog

## 2026-06-12

- Added a first structural split for findings `#5` and `#6` from `docs/architecture_review.md`.
- Extracted local plane presentation lifecycle out of `scripts/world_character_spawner.gd` into `scripts/local_plane_presentation_binding.gd`.
- Extracted bot-pilot setup out of `scripts/world_character_spawner.gd` into `scripts/plane_bot_setup.gd`.
- Added `class_name` to core gameplay and presentation scripts so stable seams have named script identities.
- Replaced a focused set of stringly calls with direct method / property use across the plane controller, world spawner, bot pilot, weapon components, HUD, and camera rig.
- Renamed `scripts/plane_missile_launcher.gd` to `scripts/missile_launcher.gd` and the runtime component class to `MissileLauncher` so the launcher is no longer plane-specific by name.
- Fixed the spawn-order regression introduced during the split by restoring `PlaneCharacter.configure(...)` before tree entry, which keeps newly spawned non-bot planes starting with the intended `100` m/s airspeed.
- Kept the authority model unchanged; this step only reduces coupling and makes the next authority migration slice easier to land.
- Verified with:
  - `godot --headless --path . --scene res://scenes/world_0.tscn --quit-after 2`
  - `res://tests/autocannon_smoke.tscn`
  - `res://tests/bot_autocannon_smoke.tscn`
  - `res://tests/missile_hardpoint_smoke.tscn`
  - `res://tests/test_camera_detach.gd`
- The full multiplayer smoke still depends on local UDP socket availability; in the current environment it failed at host / join socket creation before gameplay assertions ran.

## 2026-06-12 (later)

- Landed the server-authoritative movement migration from `docs/mp_plan.md`.
- Clients now send sequenced input intent instead of final poses; the server simulates all planes and broadcasts authoritative snapshots.
- Clients predict only their own living plane and reconcile against server snapshots using per-seq history plus smooth correction instead of rewind/replay.
- The server now owns the aero tables in multiplayer and sends them during world sync so client prediction uses the same flight model.
- Ground-impact damage is now judged server-side; the client self-report path was removed.
- Extended multiplayer smokes so the host verifies that a remote player plane actually moves under server simulation.

## 2026-06-13

- Followed up on multiplayer jitter after the authority migration.
- Added angular-velocity reconciliation for own-plane prediction so sustained pitch/turn cases no longer drift rotationally as badly.
- Sent simulation-relevant control-state flags with each input packet (active pitch/yaw/roll state, relative-roll mode, pitch assist, stabilization assist, limiter override) so the server no longer simulates remote-player planes with silently different assist behavior.
- Sent the post-limiter effective pitch command the client predicted with, and used that effective pitch on the server net-input path to reduce limiter divergence during sharp turns.
- Reworked client missile and bullet visuals to use replica versions of the real `Missile` / `Bullet` simulation paths instead of separate kinematic approximations; server authority over collision/damage remains unchanged.
- Fixed projectile replica init order so nodes enter the tree before replica code touches global transform or `look_at()`.
- Kept autocannon lead math in relative space to reduce far-from-origin precision loss in multiplayer gunnery.
- Moved autocannon spawn off the exact plane center to a single forward muzzle point; removed the later dual-hardpoint experiment because it looked worse in practice.
- Smoothed wing-trail point sampling with a lag cap so local contrails no longer advertise every tiny reconciliation correction.
- Multiplayer headless smokes now pass in the current environment; recent work was repeatedly validated with `bash tests/run_headless_smokes.sh`.

---


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

8. Assist toggles and keybindings
- Added a bindable pitch-assist toggle that disables both the max-lift and sustain-turn pitch limiter stack when turned off.
- Added a bindable stabilization-assist toggle that disables player pitch/roll/yaw stabilization torque when turned off.
- Both assists default to on; `toggle_pitch_assist` defaults to `O` and `toggle_stabilization_assist` defaults to `P`.
- Added a bindable input-decay toggle that disables decay-to-neutral for pitch, roll, and yaw inputs when turned off, causing released controls to hold their last commanded values.
- `toggle_input_decay` defaults to `I` and starts enabled.
- Multiplayer lobby now exposes a host-controlled bot count setting, including `0`, and `world_character_spawner.gd` reads that setting before spawning world bots so flight-model tests can start without AI traffic.
- Added separate analog-axis bindings for `Pitch`, `Yaw`, and `Roll` in the keybindings menu, each with a live input meter and an invert toggle.
- Plane input collection now reads those analog bindings directly alongside the existing digital actions, so flight sticks and rudder pedals can drive the same control channels without replacing the keyboard path.
- Analog pitch, yaw, and roll now bypass the digital ramp/decay behavior while active, so stick and pedal deflection maps 1:1 to control input instead of building up over time.
- Added a tunable local camera shake that activates when AoA exceeds the lift-table-derived max-lift threshold, scaling with exceedance magnitude instead of raw pitch input.
- Pitch assist, stabilization assist, and input decay now persist through restart via `user://display_settings.cfg` instead of resetting to on every new run.

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

---

Date: June 12, 2026

## Summary

Architecture review follow-up: further progress on items #5, #6, and #8 from `docs/architecture_review.md`.

## Completed Work

1. God objects / mixed responsibilities (#5) — no new splits this pass; existing splits from prior work stand.

2. Stringly-typed contracts (#6)
- Added `class_name ForceDebugRenderer3D` to `force_debug_renderer_3d.gd` and `class_name BotDebugRenderer3D` to `bot_debug_renderer_3d.gd`. Both now have globally registered types.
- Replaced all `.call("method_name")` and `.has_method(...)` guards against debug renderers with direct method calls in `plane_character_controller.gd` and `plane_bot_pilot.gd`. Hosting variables left untyped because Godot 4 cannot resolve a `class_name` as a type annotation in the same script that also `preload`s the defining file.
- Removed the stringly-typed `_get_persisted_assist_setting` / `_persist_assist_setting` helpers from `PlaneCharacter`. Assist-setting persistence now reads and writes the `DisplaySettings` autoload singleton directly. `DisplaySettings` cannot carry a `class_name` because Godot 4 raises a parse error when a `class_name` matches an autoload registration name.
- `PlaneBotPilot._plane` is now typed as `PlaneCharacter`; `is_in_group("plane_character")` checks replaced with `as PlaneCharacter` casts.
- `WorldCharacterSpawner._on_projectile_entered` now casts to `Missile` and uses `Missile.linear_velocity`, `Missile.target`, and the `died` signal directly; removed `scene_file_path`, `has_signal`, and `"target" in node` string guards.
- `WorldCharacterSpawner.submit_character_state` now uses `as PlaneCharacter` for the shot-down guard instead of `is_in_group`.

3. Documentation drift (#8)
- Added status headers to `health.md`, `plane_physics_spec.md`, `testing_scenes.md`, `dev_plan.md`, `fixed_wing_bot_autopilot_summary.md`, and `view_distance.md`.
- Updated `architecture_review.md` summary table and body sections to reflect current state of items #5, #6, and #8.
- Later revised: status headers now live only on architecture/process docs; mechanism docs (plane, missiles, health, autocannon, bot behavior) explain how the system works and what its parameters do, nothing else.

---

Date: June 12, 2026 (later)

## Summary

Server-authoritative movement migration (architecture review item #1, option B): clients now send input intent, the server simulates every plane, and clients predict + reconcile their own plane. The server defines the aero tables. Design contract in `docs/mp_plan.md`.

## Completed Work

1. Input intent channel
- `PlaneCharacter` emits `local_input_produced` with `{seq, roll, pitch, yaw, throttle}` every physics tick when running as a predicting client; the spawner forwards it via the new `sv_submit_input` RPC (unreliable_ordered, channel 1).
- The wire carries the post-smoothing control state, so the server does not replicate mouse/assist/decay logic; values are validated (finite, seq-monotonic) and clamped to `[-1, 1]`.
- `submit_character_state`, `_sanitize_submitted_snapshot`, and the `MAX_SUBMITTED_*` pose clamps are deleted — there is no client pose to sanitize anymore.

2. Server simulation of all planes
- `_is_simulated_locally()` reworked: the server simulates every plane; a pure client simulates only its own living plane; single player is unchanged.
- Remote players' planes on the server run a third input mode, `_apply_net_inputs()` (latest-wins, direct application), alongside bot injection and local input collection; the applied seq is latched per tick as the snapshot `ack_seq`.
- The server broadcasts `apply_character_state` for every plane to every world-ready peer, including the owner (the echo carries `ack_seq` for reconciliation).
- Ground-impact damage is now observed entirely server-side; the `sv_report_ground_impact` self-report RPC is deleted.

3. Client prediction + reconciliation
- The owner client keeps a per-seq prediction history ring; on each own-plane snapshot it compares the server state against its recorded state at `ack_seq`.
- Within tolerance nothing happens; beyond tolerance the position error becomes a pending correction folded in smoothly over subsequent ticks (history is shifted by the folded amount so later acks measure only remaining error); rotation/velocity get fractional blends; beyond `reconcile_hard_snap_distance` the plane snaps to the server state.
- No rewind/replay: Godot physics is not deterministic and `RigidBody3D` cannot re-step; error-offset smoothing is the standard alternative.
- Shot-down handover: a dead plane on the owner client stops predicting and is interpolated like a remote; the wreck spin impulse is rolled only by the simulation authority, so wrecks tumble identically on all screens.

4. Server-defined aero tables
- `user://plane_aero_tables.json` is only loaded by the simulation authority (single player or server); a client's local file is ignored in multiplayer.
- The server captures the effective tables once and sends them via `cl_apply_aero_tables` during world sync, before spawn sync on the same reliable channel; clients apply them to current and future planes so prediction matches the server's flight model.

5. Tests
- `tests/mp_host_smoke.gd` now also asserts the remote player's plane actually moves on the host (server simulation driving it, ≥50 m displacement).
- `tests/mp_client_smoke.gd` now lingers after its health-sync success instead of quitting immediately, so the host smoke can observe the client plane; it completes when the linger elapses or the session ends.
- Full headless suite passes: autocannon, bot autocannon, missile hardpoint, camera detach (17 asserts), mp host + client smokes; `bot_duel.tscn` boots clean in single player.

---

Date: June 12, 2026 (later follow-up)

## Summary

Follow-up pass on the new server-authoritative movement model: prediction was functionally correct but still too twitchy under sustained turns, and projectile/trail visuals were diverging from server truth. This pass tightened client/server control-state parity, reconciled angular motion, and replaced projectile approximations with client replicas of the real server flight paths.

## Completed Work

1. Plane prediction parity and jitter reduction
- Own-plane reconciliation now includes `angular_velocity` in prediction history, snapshots, hard-snap state, and blend correction. This removed a major source of persistent “high-ping” feel during pitch-hold turns.
- The client now sends the control-state booleans that actually affect simulation, not just smoothed axes: pitch/yaw/roll-active state, relative-roll-target activity, pitch assist, stabilization assist, and limiter override.
- The server's net-input path now applies those flags before simulating remote-player planes, so stabilization damping and limiter behavior match client prediction instead of silently diverging.
- The client also sends the post-limiter effective pitch command it predicted with; the server uses that effective pitch for remote-player torque instead of recomputing a slightly different limiter result from its own instantaneous state.

2. Contrail shake cleanup
- Wing contrails were client-side, but they were still sampling the corrected plane body transform directly, so small reconciliation nudges produced visible zigzags.
- `VisualTrail3D` now supports smoothed point sampling with a lag cap; wing contrails use that smoothing, which removes most of the sawtooth noise without letting the trail origin drift arbitrarily far behind the plane.
- Contrail activation was also cleaned up earlier in the same pass so it keys off actual flight state (`linear_velocity`, AoA, local pitch rate) instead of frame-to-frame corrected position deltas.

3. Missile replication parity
- The old `MissileVisual` path was a separate kinematic approximation of the real missile and diverged visibly from the authoritative `RigidBody3D` missile even when spawn velocity was correct.
- Clients now spawn real `Missile` replicas that run the same thrust/drag/guidance/stabilization code as the server missile, with client-side collision/damage authority disabled. Server despawn/explosion RPCs still decide outcomes.
- Replica spawn ordering was fixed so missiles and bullets are added to the tree before replica init touches global transform or `look_at()`.

4. Bullet replication parity and large-world aim cleanup
- Client bullets no longer use the old `BulletVisual` approximation; they now spawn real `Bullet` replicas with client-side collision authority disabled.
- Autocannon intercept math was changed to stay in relative space instead of reconstructing aim from two large absolute positions after the relative vector was already known. This reduces far-from-origin precision loss in multiplayer gunnery.
- Autocannon bullets now spawn from an explicit forward muzzle offset instead of the plane center. The lateral alternating hardpoint experiment was removed; the final path uses a single forward muzzle point only.

5. Outcome
- Compared with the original authority-migration state, the local plane now tracks server truth much more closely under sustained turning, missiles look substantially closer to what the server is simulating, and contrails no longer advertise every tiny reconciliation correction.
- Remaining known imperfections are smaller tuning/representation issues rather than the original structural mismatch between client prediction and server simulation.
