#!/usr/bin/env bash
# X11 placement acceptance for the Mubi companion (issue #104).
#
# Verifies the safety-critical parts of the temporary drag mode without a
# human at the desktop:
#   1. outside placement the surface's X11 input shape is empty (pointer-through);
#   2. placement makes only a bounded region sensitive, a real pointer drag moves
#      the window, and the normalized position is persisted;
#   3. the 30 s timeout restores the empty input region.
#
# Needs: Xvfb or an X11 display, xdotool, gcc, libX11/libXext headers.
# Usage: Xvfb :99 & DISPLAY=:99 bash scripts/e2e/linux-placement.sh
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="$repo/.rivet/acceptance/linux-placement"
mkdir -p "$out"
exe="$(find "$repo/dist" -type f -name RivetHost -perm -u+x -print -quit 2>/dev/null || true)"
[[ -n "$exe" ]] || exe="$repo/.rivet/stage/RivetHost"
[[ -x "$exe" ]] || { echo "no packaged RivetHost in dist/ or .rivet/stage/" >&2; exit 1; }
command -v xdotool >/dev/null || { echo "xdotool is required" >&2; exit 1; }
command -v Xvfb >/dev/null || { echo "Xvfb is required" >&2; exit 1; }

cat > "$out/xshape.c" <<'C'
#include <X11/Xlib.h>
#include <X11/extensions/shape.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char** argv) {
  Display* d = XOpenDisplay(NULL);
  if (!d || argc < 2) return 2;
  Window w = (Window)strtoul(argv[1], NULL, 0);
  int n = 0, ord = 0;
  XRectangle* r = XShapeGetRectangles(d, w, ShapeInput, &n, &ord);
  printf("%d\n", n);
  if (r) XFree(r);
  XCloseDisplay(d);
  return 0;
}
C
gcc -O2 -o "$out/xshape" "$out/xshape.c" -lX11 -lXext

xvfb_pid=''
if [[ -z "${DISPLAY:-}" ]]; then
  Xvfb :99 -screen 0 1280x900x24 >"$out/xvfb.log" 2>&1 & xvfb_pid=$!
  export DISPLAY=:99
  sleep 1
fi
stop_app() {
  [[ -n "${app_pid:-}" ]] || return 0
  kill -TERM "$app_pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    kill -0 "$app_pid" 2>/dev/null || break
    sleep .05
  done
  kill -KILL "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  app_pid=''
}
cleanup() {
  status=$?
  stop_app
  [[ -n "$xvfb_pid" ]] && kill "$xvfb_pid" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT

data="$out/data"; home="$out/home-$$"
rm -rf "$data" "$home"; mkdir -p "$data" "$home"
printf '%s\n' '{"SchemaVersion":4,"WelcomeShown":true,"Language":"en","SoundEnabled":false,"AutoCheckUpdates":false}' > "$data/config.json"

start_app() {
  env HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/share" \
      XDG_CACHE_HOME="$home/cache" GDK_BACKEND=x11 GSK_RENDERER=cairo \
      MOVEBIT_DATA_DIR="$data" MOVEBIT_BOOTSTRAP_DIR="$data" \
      ${1:+MOVEBIT_PLACEMENT_TEST=1} "$exe" >"$out/application.log" 2>&1 &
  app_pid=$!
  win=''
  for _ in $(seq 1 200); do
    win="$(xdotool search --name '^Mubi$' 2>/dev/null | head -1 || true)"
    [[ -n "$win" ]] && break
    sleep .05
  done
  [[ -n "$win" ]] || { echo "Mubi window did not appear" >&2; exit 1; }
}

# 1. Default: pointer-through.
start_app
shipped="$(DISPLAY="$DISPLAY" "$out/xshape" "$win")"
stop_app
[[ "$shipped" == "0" ]] || { echo "pointer-through broken: $shipped input rectangles" >&2; exit 1; }

# 2. Placement: bounded region, drag, persistence.
start_app placement
active="$(DISPLAY="$DISPLAY" "$out/xshape" "$win")"
[[ "$active" -ge 1 && "$active" -le 2 ]] || { echo "unexpected placement region: $active" >&2; exit 1; }
before="$(xwininfo -id "$win" | awk '/Absolute upper-left X/{x=$4}/Absolute upper-left Y/{y=$4}END{print x","y}')"
xdotool mousemove --window "$win" 30 40
sleep .2
xdotool mousedown 1
sleep .2
xdotool mousemove_relative --sync -- -50 -35
sleep .2
xdotool mousemove_relative --sync -- -50 -35
sleep .2
xdotool mouseup 1
sleep .8
after="$(xwininfo -id "$win" | awk '/Absolute upper-left X/{x=$4}/Absolute upper-left Y/{y=$4}END{print x","y}')"
[[ "$before" != "$after" ]] || { echo "drag did not move the window" >&2; exit 1; }
free_x=-1; free_y=-1
for _ in $(seq 1 80); do
  read -r free_x free_y < <(python3 - "$data/config.json" <<'PY2'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    d={}
print(d.get("CompanionFreeX",-1), d.get("CompanionFreeY",-1))
PY2
)
  [[ "$free_x" != "-1" ]] && break
  sleep .05
done
[[ "$free_x" -ge 0 && "$free_x" -le 1000 && "$free_y" -ge 0 && "$free_y" -le 1000 ]] \
  || { echo "free position not persisted: $free_x,$free_y" >&2; exit 1; }

# 3. Timeout restores pointer-through (the test may shorten it).
wait_seconds="${MOVEBIT_PLACEMENT_TIMEOUT_SECONDS:-32}"
sleep "$((wait_seconds > 30 ? 32 : wait_seconds + 2))"
restored="$(DISPLAY="$DISPLAY" "$out/xshape" "$win")"
[[ "$restored" == "0" ]] || { echo "timeout left input captured: $restored" >&2; exit 1; }

cat > "$out/result.json" <<JSON
{"format":"movebit-placement-acceptance","format-version":1,"platform":"linux-x11",
 "pointer-through-default":true,"placement-region-rectangles":$active,
 "window-before":"$before","window-after":"$after",
 "free-position":{"x":$free_x,"y":$free_y},
 "pointer-through-restored":true}
JSON
echo "placement acceptance PASS"
