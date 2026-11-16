#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"; output="$repo/.rivet/acceptance/macos"; data="$output/data"; home="$output/home-$$"
app="$(find "$repo/dist" -type f -path '*/Contents/MacOS/*' -perm -u+x -print -quit)"; driver="$output/macos-ax"
mkdir -p "$output" "$data" "$home"; racket "$repo/scripts/acceptance/profile.rkt" seed "$data"
[[ -n "$app" && -x "$app" ]]; swiftc "$repo/scripts/e2e/macos-ax.swift" -o "$driver" -framework AppKit -framework ApplicationServices
HOME="$home" MOVEBIT_DATA_DIR="$data" MOVEBIT_BOOTSTRAP_DIR="$data" MOVEBIT_ACCEPTANCE=1 "$app" >"$output/application.log" 2>&1 & app_pid=$!
cleanup(){ status=$?;trap - EXIT;kill -TERM "$app_pid" 2>/dev/null || true;wait "$app_pid" 2>/dev/null || true;exit "$status";};trap cleanup EXIT
"$driver" --pid "$app_pid" --output "$output"
for _ in $(seq 1 200);do kill -0 "$app_pid" 2>/dev/null || break;sleep .05;done
kill -0 "$app_pid" 2>/dev/null && { echo 'MoveBit did not exit after native termination' >&2;exit 1;} || true
wait "$app_pid";trap - EXIT
