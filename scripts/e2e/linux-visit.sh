#!/usr/bin/env bash
# X11 invitation acceptance for the Mubi companion (2026-11-15 contract).
#
# A genuine due cue attaches the invitation to the pet and WAITS there:
#   1. the companion does NOT travel to the work-area centre (the old
#      central-visit behavior is retired by the 2026-11-15 redesign);
#   2. the invitation arms the input region while it waits (buttons +
#      checklist reachable), and it persists unanswered — no auto-hide;
#   3. petting (a click on the character) is companionship ONLY: it never
#      settles the invitation (the region stays armed, the window stays).
# Completion submits via the invitation buttons / tray / micro window.
# Needs Xvfb (or DISPLAY), xdotool.
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

# Input-shape reader (same probe as the placement acceptance).
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
racket "$repo/scripts/acceptance/profile.rkt" seed "$data"
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

# The hook delivers the cue at ~2.5 s. The 2026-11-15 contract: the
# invitation attaches to the pet — the companion must NOT travel to the
# work-area centre (the invitation bubble legitimately reflows the window
# around its dock, but the pet stays in its corner neighborhood), and the
# input region must arm (buttons + checklist reachable).
traveled=0
start=$(date +%s)
while (( $(date +%s) - start < 8 )); do
  read -r x y <<<"$(geometry)"
  geo="$(xdotool getwindowgeometry --shell "$win")"
  w="$(awk -F= '/^WIDTH=/{print $2}' <<<"$geo")"
  h="$(awk -F= '/^HEIGHT=/{print $2}' <<<"$geo")"
  cx=$((x + w / 2)); cy=$((y + h / 2))
  # Central third of the 1280x900 Xvfb work area = the retired visit target.
  if (( cx > 420 && cx < 860 && cy > 230 && cy < 670 )); then
    traveled=1
    break
  fi
  sleep .05
done
(( traveled == 0 )) || {
  echo "Mubi traveled to the work-area centre on a due cue (centre $cx,$cy); the 2026-11-15 contract keeps the invitation at the pet" >&2
  exit 1
}
echo "no-visit: companion stayed near its dock with the cue due"

# Arm the region: rest the pointer on the window, the input shape grows
# beyond the empty (pointer-through) state while the invitation waits.
xdotool mousemove --window "$win" 60 60
active=0
for _ in $(seq 1 40); do
  active="$(DISPLAY="$DISPLAY" "$out/xshape" "$win" 2>/dev/null || echo 0)"
  [[ "$active" -ge 1 ]] && break
  sleep .05
done
(( active >= 1 )) || { echo "invitation did not arm the input region" >&2; exit 1; }
echo "invitation: input region armed ($active rectangles) while waiting"

# Petting is companionship ONLY: a click on the character must NOT settle
# the invitation — the region stays armed and the window stays put.
geo2="$(xdotool getwindowgeometry --shell "$win")"
px="$(awk -F= '/^X=/{print $2}' <<<"$geo2")"
py="$(awk -F= '/^Y=/{print $2}' <<<"$geo2")"
pw="$(awk -F= '/^WIDTH=/{print $2}' <<<"$geo2")"
ph="$(awk -F= '/^HEIGHT=/{print $2}' <<<"$geo2")"
click_x=$((px + pw / 2)); click_y=$((py + ph * 35 / 100))
xdotool mousemove "$click_x" "$click_y" click 1
sleep 1.2
read -r after_x after_y <<<"$(geometry)"
still_armed=0
for _ in $(seq 1 20); do
  n="$(DISPLAY="$DISPLAY" "$out/xshape" "$win" 2>/dev/null || echo 0)"
  if [[ "$n" -ge 1 ]]; then still_armed=1; break; fi
  sleep .1
  xdotool mousemove --window "$win" 60 60
done
(( still_armed == 1 )) || {
  echo "petting settled the invitation — the 2026-11-15 contract forbids that (petting is companionship only)" >&2
  exit 1
}
(( after_x == idle_x && after_y == idle_y )) || {
  echo "petting moved the companion ($idle_x,$idle_y -> $after_x,$after_y)" >&2
  exit 1
}
echo "petting: invitation still waiting (armed, $after_x,$after_y) — no completion recorded"
echo "linux invitation acceptance PASS"
