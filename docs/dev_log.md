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
