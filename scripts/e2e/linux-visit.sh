#!/usr/bin/env bash
# X11 central-visit acceptance for the Mubi companion (issue #140).
#
# A genuine due cue must approach the work-area centre and HOLD there —
# the invitation is persistent and never auto-returns (there is no timer
# that ends it). A click on the character is the pet gesture: it
# acknowledges (self-reported Done) and Mubi walks back to the exact
# persisted home. Needs Xvfb (or DISPLAY), xdotool.
# Usage: DISPLAY=:99 bash scripts/e2e/linux-visit.sh [path-to-RivetHost]
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="$repo/.rivet/acceptance/linux-visit"
mkdir -p "$out"
exe="${1:-}"
if [[ -z "$exe" ]]; then
  exe="$(find "$repo/dist" -type f -name RivetHost -perm -u+x -print -quit 2>/dev/null || true)"
fi
[[ -n "$exe" ]] || exe="$repo/.rivet/stage/RivetHost"
[[ -x "$exe" ]] || { echo "no RivetHost (pass one, or package into dist/)" >&2; exit 1; }
command -v xdotool >/dev/null || { echo "xdotool is required" >&2; exit 1; }
command -v Xvfb >/dev/null || { echo "Xvfb is required" >&2; exit 1; }

xvfb_pid=''
if [[ -z "${DISPLAY:-}" ]]; then
  Xvfb :98 -screen 0 1280x900x24 >"$out/xvfb.log" 2>&1 & xvfb_pid=$!
  export DISPLAY=:98
  sleep 1
fi
cleanup() {
  status=$?
  if [[ -n "${app_pid:-}" ]]; then
    kill -TERM "$app_pid" 2>/dev/null || true
    for _ in $(seq 1 200); do
      kill -0 "$app_pid" 2>/dev/null || break
      sleep .05
    done
    kill -KILL "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  [[ -n "$xvfb_pid" ]] && kill "$xvfb_pid" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT

data="$out/data"; home="$out/home-$$"
rm -rf "$data" "$home"; mkdir -p "$data" "$home"
printf '%s\n' '{"SchemaVersion":4,"WelcomeShown":true,"Language":"en","SoundEnabled":false,"AutoCheckUpdates":false}' > "$data/config.json"
env HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/share" \
    XDG_CACHE_HOME="$home/cache" GDK_BACKEND=x11 GSK_RENDERER=cairo \
    MOVEBIT_DATA_DIR="$data" MOVEBIT_BOOTSTRAP_DIR="$data" \
    MOVEBIT_VISIT_TEST=1 "$exe" >"$out/application.log" 2>&1 &
app_pid=$!

win=''
for _ in $(seq 1 300); do
  win="$(xdotool search --name '^Mubi$' 2>/dev/null | head -1 || true)"
  [[ -n "$win" ]] && break
  sleep .05
done
[[ -n "$win" ]] || { echo "Mubi window did not appear" >&2; cat "$out/application.log" >&2; exit 1; }

geometry() {
  xdotool getwindowgeometry --shell "$win" | awk -F= '/^X=/{x=$2} /^Y=/{y=$2} END{print x, y}'
}
read -r idle_x idle_y <<<"$(geometry)"
[[ "$idle_x" -gt 0 && "$idle_y" -gt 0 ]] || { echo "invalid home geometry" >&2; exit 1; }

# The hook delivers the cue at ~2.5 s; watch until the window has moved left
# toward the central third, then verify it HOLDS there — an unanswered
# invitation never auto-returns (issue #140).
moved=0; near_center=0; start=$(date +%s)
while (( $(date +%s) - start < 8 )); do
  read -r x y <<<"$(geometry)"
  if (( x < idle_x - 120 )); then moved=1; fi
  if (( x > 400 && x < 800 )); then near_center=1; break; fi
  sleep .05
done
(( moved == 1 )) || { echo "Mubi did not approach the central third (home $idle_x,$idle_y)" >&2; exit 1; }
(( near_center == 1 )) || { echo "Mubi approached but not near the work-area centre ($x,$y)" >&2; exit 1; }
echo "approach: home $idle_x,$idle_y -> centre $x,$y"

held=1; start=$(date +%s)
while (( $(date +%s) - start < 14 )); do
  read -r x y <<<"$(geometry)"
  # Still at (or near) the centre: no auto-return, no drift home.
  if (( x < idle_x - 120 )); then held=0; break; fi
  sleep .1
done
(( held == 1 )) || { echo "Mubi left the centre unanswered ($x,$y) — invitations must persist (issue #140)" >&2; exit 1; }
read -r hold_x hold_y <<<"$(geometry)"
echo "hold: still at centre $hold_x,$hold_y after 14 s unanswered"

# Pet = Done: a click on the character acknowledges the cue and Mubi walks
# back to the exact persisted home. The click lands inside the canvas input
# region (XShape) — this also proves the pet region is live on X11.
geo2="$(xdotool getwindowgeometry --shell "$win")"
px="$(awk -F= '/^X=/{print $2}' <<<"$geo2")"
py="$(awk -F= '/^Y=/{print $2}' <<<"$geo2")"
pw="$(awk -F= '/^WIDTH=/{print $2}' <<<"$geo2")"
ph="$(awk -F= '/^HEIGHT=/{print $2}' <<<"$geo2")"
click_x=$((px + pw / 2)); click_y=$((py + ph * 35 / 100))
xdotool mousemove "$click_x" "$click_y" click 1
echo "pet: clicked character at $click_x,$click_y"

returned=0; start=$(date +%s)
while (( $(date +%s) - start < 14 )); do
  read -r x y <<<"$(geometry)"
  if (( x == idle_x && y == idle_y )); then returned=1; break; fi
  sleep .1
done
(( returned == 1 )) || { echo "petting did not walk Mubi home ($idle_x,$idle_y); now $x,$y" >&2; exit 1; }
echo "return: exact home restored after petting ($x,$y)"
echo "linux central visit PASS"
