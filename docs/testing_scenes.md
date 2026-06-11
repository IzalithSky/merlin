# Testing Scenes

Date: June 11, 2026

This note documents the lightweight scene-testing workflow used for Merlin while making targeted gameplay and networking fixes.

## Goal

Use fast, repeatable checks that answer:

- Does the edited scene/script still parse and instantiate?
- Does the scene boot in project context without immediate runtime errors?
- Can a narrow behavior be exercised without launching the full menu flow?

## Baseline Scene Boot Check

For most gameplay changes, start with a headless load of the relevant scene in normal project context.

Example pattern:

```bash
godot --headless --path . --scene res://scenes/world_0.tscn --quit-after 2
```

Why this is useful:

- Loads autoloads and project settings normally.
- Catches script parse errors, scene wiring mistakes, and many startup-time runtime errors.
- Finishes quickly enough to run after small patches.

## When To Prefer Scene Boot

Use a direct scene boot when:

- The edited code depends on autoload singletons.
- The target behavior lives inside an existing game scene.
- You mainly need confidence that the project still loads after a refactor or bug fix.

This was the default check for:

- HUD and options-menu wiring
- multiplayer snapshot changes
- missile / bot logic changes
- input-map and autoload-related fixes

## Narrow Behavior Checks

If a fix is smaller than a full end-to-end session, prefer a focused harness:

1. Load one real scene or node.
2. Exercise only the changed code path.
3. Assert or print the specific state you care about.
4. Keep the harness disposable unless it is stable enough to keep as a regression test.

Good examples:

- spawn one plane and trigger shot-down behavior
- invoke a damage path and verify HP/state transitions
- feed one remote snapshot and confirm interpolation state updates

## Avoiding False Confidence

Headless scene boot is useful, but it is not a replacement for real multiplayer or gameplay verification.

It does not prove:

- good feel under latency/jitter
- correct long-session authority behavior
- correctness of peer connection sequencing
- correctness of visual-only effects that depend on player interaction timing

Use it as a fast gate, not as the only test.

## Practical Workflow

Recommended order after a gameplay patch:

1. Run a headless boot of the most relevant scene.
2. Fix any parse/runtime errors immediately.
3. If the change is networked or stateful, add a narrow harness only if the behavior cannot be reasoned about locally.
4. Prefer deleting ad hoc harnesses over keeping flaky tests that require special environment setup.

## Current Smoke Set

The repository now has a small headless smoke suite covering both local leaf
features and one real multiplayer path:

- `res://tests/autocannon_smoke.tscn`
- `res://tests/bot_autocannon_smoke.tscn`
- `res://tests/missile_hardpoint_smoke.tscn`
- `res://tests/test_camera_detach.gd`
- `res://tests/mp_host_smoke.gd` + `res://tests/mp_client_smoke.gd`

Run them together with:

```bash
tests/run_headless_smokes.sh
```

The multiplayer smoke asserts:

- host + client both reach `world_0.tscn`
- exactly one local non-bot plane exists per peer
- both peers spawn both player planes
- host-side damage on the remote player replicates to the client health view

## Command Guidelines

- Use project-relative scene paths such as `res://scenes/world_0.tscn`.
- Keep `--quit-after` short for startup checks.
- Run the smallest scene that still exercises the edited code in project context.
- If a script depends on autoloads, avoid standalone script execution that bypasses normal scene boot unless you recreate that context explicitly.
