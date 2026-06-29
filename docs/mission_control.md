# Mission Control

`MissionController` owns mission-driven spawning and single-player mission rules.

## Principles

- Loads one mission JSON file.
- Spawns mission-defined players and mobs.
- Uses mission player spawns when present.
- Uses legacy free-for-all spawning only when the mission has no player specs.
- Runs mission mob spawning on single-player and on the multiplayer server.
- Owns single-player score, timer, victory, and game-over flow.

## Script

Main script: `scripts/mission_controller.gd`

Scene node: `MissionController` in `scenes/match_systems.tscn`

## Mission File

Mission files live in `data/missions/`.

Current examples:

- `data/missions/default.json`
- `data/missions/ffa.json`
- `data/missions/coop.json`

## Top-Level Params

- `name`: mission id/name.
- `player_limit`: max multiplayer players for this mission. `-1` means no mission cap.
- `required_score`: single-player victory score. `0` disables score victory.
- `mission_time_limit_sec`: single-player timer. `0` disables timer.
- `seed`: optional RNG seed for area-based random spawns.
- `areas`: named spawn volumes.
- `players`: ordered player spawn specs.
- `mobs`: mission mob specs.

## Areas

Two supported forms:

- `min` / `max`
- `center` / `size`

Example:

```json
"areas": {
  "battlefield": {
    "center": [0, 0, 0],
    "size": [6000, 6000, 6000]
  }
}
```

## Player Specs

Supported fields:

- `position`: `[x, y, z]`, required.
- `team`: numeric team id, default `1`.
- `yaw`: radians, default `0.0`.
- `speed`: forward spawn speed, default `100`.

Notes:

- In multiplayer, player specs are assigned in sorted peer-id order.
- If there are more players than mission `players` entries, extra players fall back to default spawns.

Example:

```json
"players": [
  { "position": [-500, 1500, 2000], "team": 1, "yaw": 0.0, "speed": 100 },
  { "position": [500, 1500, 2000], "team": 1, "yaw": 0.0, "speed": 100 }
]
```

## Mob Specs

Supported `type` values:

- `plane_bot`
- `zeppelin`
- `ground_aa`
- `ground_sam`

Common fields:

- `type`: mob type, required.
- `team`: numeric team id.
- `count`: spawn count, default `1`.
- `position`: `[x, y, z]`
- `area`: named area or inline area object
- `overrides`: property overrides applied after spawn

### `plane_bot`

Extra fields:

- `yaw`
- `speed`

Example:

```json
{ "type": "plane_bot", "team": 2, "position": [500, 1500, -2000], "yaw": 3.1415927, "speed": 100 }
```

### `zeppelin`

Supported forms:

- `position`
- `a` / `b`

Notes:

- If only one point is given, it hovers there.
- If `a` and `b` are given, it moves between them.

Example:

```json
{ "type": "zeppelin", "team": 2, "a": [-2500, 700, -800], "b": [2500, 700, -800], "speed": 30 }
```

### Ground Units

Ground units use `position`, but only `x` and `z` matter for placement.

Example:

```json
{ "type": "ground_aa", "team": 2, "position": [-1500, 0, -500] }
```

## Single-Player Rules

Mission control handles:

- HUD hookup
- score counting from hostile shot-down events
- timer countdown
- victory on score target
- victory when all tracked hostiles are destroyed
- game over on local player death
- game over on timer expiry

These rules are mission-controlled only for single-player.

## Short Examples

### Free For All

```json
{
  "name": "ffa",
  "player_limit": -1,
  "players": [],
  "mobs": []
}
```

### Co-op

```json
{
  "name": "coop",
  "player_limit": 4,
  "players": [
    { "position": [-1500, 1500, 2000], "team": 1 },
    { "position": [-500, 1500, 2000], "team": 1 }
  ],
  "mobs": [
    { "type": "plane_bot", "team": 2, "position": [-500, 1500, -2000], "yaw": 3.1415927 },
    { "type": "ground_sam", "team": 2, "position": [0, 0, -2200] }
  ]
}
```

### Single-Player Mission

```json
{
  "name": "default",
  "player_limit": 1,
  "required_score": 6,
  "mission_time_limit_sec": 240,
  "players": [
    { "position": [-500, 1500, 2000], "team": 1 }
  ],
  "mobs": [
    { "type": "plane_bot", "team": 2, "position": [500, 1500, -2000], "yaw": 3.1415927 }
  ]
}
```
