#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${GODOT_BIN:?Set GODOT_BIN to your Godot executable path before running this script.}"
TMP_DIR="${TMPDIR:-/tmp}"
HOST_LOG="$TMP_DIR/merlin_mp_host.log"
CLIENT_LOG="$TMP_DIR/merlin_mp_client.log"

run_scene() {
  local scene_path="$1"
  HOME=/tmp XDG_DATA_HOME=/tmp "$GODOT_BIN" --headless --path "$ROOT_DIR" --scene "$scene_path"
}

run_script() {
  local script_path="$1"
  HOME=/tmp XDG_DATA_HOME=/tmp "$GODOT_BIN" --headless --path "$ROOT_DIR" --script "$script_path"
}

run_scene "res://tests/autocannon_smoke.tscn"
run_scene "res://tests/bot_autocannon_smoke.tscn"
run_scene "res://tests/bot_aggro_smoke.tscn"
run_scene "res://tests/world_bot_spawn_speed_smoke.tscn"
run_scene "res://tests/world_level_randomizer_smoke.tscn"
run_scene "res://tests/missile_hardpoint_smoke.tscn"
run_script "res://tests/test_camera_detach.gd"
run_script "res://tests/net_wire_smoke.gd"

rm -f "$HOST_LOG" "$CLIENT_LOG"
(
  HOME=/tmp XDG_DATA_HOME=/tmp timeout 15s "$GODOT_BIN" --headless --path "$ROOT_DIR" --script res://tests/mp_host_smoke.gd >"$HOST_LOG" 2>&1
) &
host_pid=$!
sleep 1
set +e
HOME=/tmp XDG_DATA_HOME=/tmp timeout 15s "$GODOT_BIN" --headless --path "$ROOT_DIR" --script res://tests/mp_client_smoke.gd >"$CLIENT_LOG" 2>&1
client_status=$?
wait "$host_pid"
host_status=$?
set -e

cat "$HOST_LOG"
cat "$CLIENT_LOG"

if [[ "$host_status" -ne 0 || "$client_status" -ne 0 ]]; then
  exit 1
fi
