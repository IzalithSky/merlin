# Godot Multiplayer Notes

Status: implemented (movement model) — the server-authoritative input-intent/simulation/snapshot flow described here is now in place (see `docs/mp_plan.md`); the project uses custom RPCs on `WorldCharacterSpawner` rather than `MultiplayerSpawner`/`MultiplayerSynchronizer`, which this document discusses as options.

This document summarizes how Godot 4 multiplayer works and what networking
architecture makes sense for Merlin.

## Short Answer

Use Godot's high-level multiplayer API with a server-authoritative model.

For Merlin, the baseline should be:

1. Main menu starts or joins a session.
2. A `Lobby` autoload owns connection state.
3. The server loads the game scene for all peers.
4. Each peer loads the same terrain/environment locally.
5. The server spawns one controlled aircraft/player rig per peer.
6. Clients send input intent to the server.
7. The server simulates important gameplay state.
8. The server replicates aircraft state back to clients.

Do not replicate static terrain, sky, lighting, or level assets over the network.
Every peer should load those from local project resources.

## Godot Multiplayer Model

Godot 4 has several networking layers:

| Layer | Purpose | Use in Merlin |
| --- | --- | --- |
| Low-level UDP/TCP/WebSocket APIs | Raw networking. Maximum control, maximum manual work. | Avoid at first. |
| `MultiplayerPeer` | Transport abstraction for peers, channels, transfer modes, and connection events. | Use through `ENetMultiplayerPeer`. |
| `MultiplayerAPI` | SceneTree-integrated multiplayer API available through each node's `multiplayer` property. | Core API. |
| RPCs | Explicit function calls between peers using `@rpc`. | Use for lobby events, inputs, commands, and one-shot events. |
| `MultiplayerSpawner` | Replicates authority-created nodes to other peers. | Use for aircraft/player/session objects. |
| `MultiplayerSynchronizer` | Replicates configured properties from authority to remote peers. | Use selectively for state snapshots. |

The typical desktop transport is `ENetMultiplayerPeer`. ENet is UDP-based, so
public hosting needs UDP port forwarding unless a relay, matchmaking service, or
custom backend is added.

## Peer IDs And Authority

Godot assigns every peer a unique ID:

- Server ID is always `1`.
- Clients receive positive peer IDs.
- By default, the server is the multiplayer authority for nodes.
- Authority can be changed per node with `set_multiplayer_authority()`.

For a first flight multiplayer implementation, keep authority simple:

- Server owns aircraft simulation, damage, spawning, despawning, session state,
  and game rules.
- Each client owns only local input collection, camera presentation, UI, and
  prediction/interpolation display code.
- Clients do not authoritatively set their final position.

## RPCs

RPCs are methods marked with `@rpc` and called with `rpc()` or `rpc_id()`.

Important constraints:

- RPC methods must exist on `Node`-derived scripts.
- Sender and receiver need matching node paths for the RPC node.
- RPC declarations should match on all peers.
- RPCs do not serialize arbitrary `Object` or `Callable` values.
- Dynamically added RPC nodes need stable/readable names.

Common RPC patterns:

```gdscript
@rpc("any_peer", "unreliable", 1)
func submit_input(input_frame: Dictionary) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	_apply_client_input(sender_id, input_frame)
```

```gdscript
@rpc("authority", "call_remote", "reliable", 0)
func show_match_message(message: String) -> void:
	_message_label.text = message
```

Use `multiplayer.get_remote_sender_id()` on the server to identify which client
called an RPC. Never trust a client-supplied peer ID argument when the API can
tell you who sent the packet.

## Transfer Modes

Godot RPCs can use these transfer modes:

| Mode | Behavior | Good for |
| --- | --- | --- |
| `reliable` | Delivered and ordered, but can stall later packets. | Session events, spawns, despawns, inventory, chat, match state. |
| `unreliable` | Low latency, can drop or reorder. | High-frequency input/state where the next packet supersedes the old one. |
| `unreliable_ordered` | Drops older packets when newer ones arrive first. | Homogeneous streams like transform snapshots, if packet sizes are stable. |

Do not use `reliable` for high-rate transform/state updates. Reliable traffic can
build a backlog and make latency worse exactly when the connection is degraded.

## Channels

Use transfer channels to prevent unrelated traffic from blocking each other.

Suggested starting layout:

| Channel | Traffic |
| --- | --- |
| `0` | Reliable session/control events. |
| `1` | Client input commands. |
| `2` | Server aircraft state snapshots. |
| `3` | Chat/debug/non-critical messages. |

Godot treats channel `0` specially by separating transfer modes internally, but
explicit channels still make traffic intent clearer and reduce accidental
head-of-line blocking between systems.

## Spawning

Use `MultiplayerSpawner` for dynamic networked objects:

- Player aircraft.
- Missiles/projectiles if they are network-visible.
- Temporary gameplay entities.
- Server-authoritative pickups/objectives if added later.

Keep spawn ownership server-side. Clients may request a spawn, but the server
decides whether it is valid.

Do not spawn static world content through multiplayer. Terrain chunks should be
loaded by each peer's local streaming system based on the local aircraft/camera.

## Synchronization

Use `MultiplayerSynchronizer` sparingly. It is convenient for simple property
replication, but high-speed flight objects often need custom snapshots so you can
control:

- Tick/frame IDs.
- Position and rotation compression.
- Velocity/angular velocity.
- Snapshot frequency.
- Interpolation delay.
- Interest/visibility per peer.
- Bandwidth budgets.

Current replicated aircraft state:

```text
peer_id
server_tick
position
rotation
linear_velocity
angular_velocity
ack_seq
```

Current high-rate wire contract:

- `sv_submit_input(data: PackedByteArray)` on channel `1`, `unreliable_ordered`
- `apply_world_snapshot(data: PackedByteArray)` on channel `2`, `unreliable_ordered`
- Every packed payload starts with one format-version byte (`1` currently).
- Input payload layout:
  - `u8 version`
  - `i32 seq`
  - `f32 roll, pitch, yaw, throttle, effective_pitch`
  - `u8 flags`
- Input flags bitmask:
  - bit `0`: `pitch_control_active`
  - bit `1`: `yaw_control_active`
  - bit `2`: `direct_roll_control_active`
  - bit `3`: `relative_roll_target_active`
  - bit `4`: `pitch_assist_enabled`
  - bit `5`: `stabilization_assist_enabled`
  - bit `6`: `limiter_override_active`
- World snapshot payload layout:
  - `u8 version`
  - `u32 server_tick`
  - `u16 plane_count`
  - repeated per plane:
    - `i32 peer_id`
    - `f32 position[3]`
    - `f32 linear_velocity[3]`
    - `f32 angular_velocity[3]`
    - `f32 rotation_quaternion[4]`
    - `i32 ack_seq`

Debug budget guard:

- `WorldCharacterSpawner` owns a rolling one-second `NetMetrics` window.
- The project currently logs bytes/s and packets/s by logical channel (`state`, `input`, `spawn`, `health`, `projectile`) when enabled.
- `packet_budget_pkts_per_sec` provides a soft per-peer warning if send rate regresses above the configured budget.

Do not synchronize large resources, mesh data, textures, terrain arrays, or
object references. Replicate small identifiers and primitive values.

## Recommended Merlin Architecture

```text
/root
  Lobby                 # Autoload. Owns network connection/session state.
  MainMenu              # Host/join/new game/exit UI.
  world                 # Game scene.
    level               # Local-only terrain and collision.
    env                 # Local-only sky, lighting, camera environment.
    players             # Network-spawned aircraft/player nodes.
      MultiplayerSpawner
    net                 # Game network coordinator.
    ui                  # Local UI/game menu.
```

Suggested scripts:

| Script | Responsibility |
| --- | --- |
| `lobby.gd` | Host, join, disconnect, peer registry, synchronized scene load. |
| `network_game.gd` | Server-side player spawning and match start coordination. |
| `aircraft_input.gd` | Local input sampling and normalization. |
| `aircraft_server.gd` | Authoritative aircraft simulation. |
| `aircraft_remote.gd` | Client interpolation/presentation for remote aircraft. |
| `aircraft_snapshot.gd` | Snapshot packing/unpacking helpers if needed. |

## Flow

Host flow:

1. Main menu calls `Lobby.host()`.
2. `Lobby` creates an `ENetMultiplayerPeer` server.
3. Server registers itself as peer `1`.
4. Server loads `world_0.tscn`.
5. Server spawns its own aircraft.
6. New clients connect and receive session/player state.

Join flow:

1. Main menu calls `Lobby.join(address)`.
2. `Lobby` creates an `ENetMultiplayerPeer` client.
3. Client waits for `connected_to_server`.
4. Server instructs client to load the game scene.
5. Client reports loaded.
6. Server spawns that client's aircraft.

Gameplay flow:

1. Client samples input every physics tick.
2. Client sends compact input frame to server.
3. Server validates and applies input.
4. Server simulates aircraft.
5. Server sends snapshots.
6. Clients interpolate remote aircraft and reconcile/predict local aircraft if
   client-side prediction is implemented.

## Security Rules

Treat all client data as untrusted.

Server must validate:

- Peer identity from `get_remote_sender_id()`.
- Input ranges.
- Input rates.
- Weapon fire rates.
- Requested spawns/despawns.
- Scene transition requests.
- Any future inventory, score, damage, or objective updates.

Clients must not decide:

- Final aircraft position.
- Hit results.
- Damage.
- Ammo/fuel/inventory.
- Mission completion.
- Match results.

For prototypes, this can feel slower to build than client-authoritative logic,
but it avoids rewriting the entire game when multiplayer stops being a toy.

## Flight-Specific Notes

Flight games need smooth motion more than exact per-frame visual agreement.

Use this priority order:

1. Stable server simulation.
2. Low-latency local controls.
3. Smooth remote interpolation.
4. Reasonable correction when prediction diverges.
5. Bandwidth control.

Avoid sending full transforms every rendered frame. Start with 10-30 server
snapshots per second for remote aircraft and tune from measurement. Local player
input can be sent at physics tick rate or batched with sequence numbers.

For large worlds:

- Keep terrain streaming local.
- Send aircraft positions in a local/floating-origin coordinate scheme if needed.
- Use stable world-sector/tile IDs plus local offsets if absolute coordinates get
  too large.
- Make sure all peers agree on the same level/version/hash before joining.

## Minimum First Milestone

The first useful multiplayer milestone should be deliberately small:

1. Add `Lobby` autoload.
2. Add `Host` and `Join` buttons to the main menu.
3. Host and client load the same `world_0.tscn`.
4. Spawn one visible placeholder aircraft or capsule per peer.
5. Move only the server-authoritative object.
6. Replicate transform snapshots to clients.
7. Confirm two local Godot instances can see each other.

Do not add weapons, terrain streaming synchronization, prediction, matchmaking,
or complex aircraft physics until this works.

## Things To Avoid

- Do not make each client authoritative over important gameplay state.
- Do not send scene resources, mesh data, or textures over RPC.
- Do not put RPC scripts on nodes with unstable paths.
- Do not use reliable RPCs for high-frequency movement snapshots.
- Do not trust client-reported peer IDs.
- Do not mix lobby/session state into aircraft control scripts.
- Do not implement prediction before basic server-authoritative replication works.

## Useful Sources

- Godot high-level multiplayer: <https://docs.godotengine.org/en/4.6/tutorials/networking/high_level_multiplayer.html>
- `ENetMultiplayerPeer`: <https://docs.godotengine.org/en/4.6/classes/class_enetmultiplayerpeer.html>
- `MultiplayerSpawner`: <https://docs.godotengine.org/en/4.6/classes/class_multiplayerspawner.html>
- `MultiplayerSynchronizer`: <https://docs.godotengine.org/en/4.6/classes/class_multiplayersynchronizer.html>
- Exporting for dedicated servers: <https://docs.godotengine.org/en/latest/tutorials/export/exporting_for_dedicated_servers.html>
- Gaffer on Games networking articles: <https://gafferongames.com/categories/game-networking/>
