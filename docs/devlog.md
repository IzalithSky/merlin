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
