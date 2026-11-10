#!/usr/bin/env bash
# Regenerate the app icon family from the canonical Mubi art (Assets/mubi/
# tokens.json — the same master data every host embeds). Never hand-edit the
# outputs; rerun this script after touching the character art.
#
#   scripts/gen-app-icons.sh
#
# Outputs: Assets/movebit.icns, Assets/icon.ico, Assets/icon.png
# Requires: jq, rsvg-convert, iconutil (macOS), python3 (stdlib only — the
# ICO container is assembled by hand, no Pillow).
#
# Two tile geometries share one SVG body (see emit_icon_svg):
#   - macOS keeps the Apple grid: 824pt squircle on a 1024 canvas (100px
#     margins, ~184 corner radius). macOS composites the canvas as-is, so
#     the margins are part of the platform shape.
#   - Windows/Linux use a dense tile: both hosts composite the raw frame
#     with no system mask or backdrop, so Apple-grid margins only shrink
#     the glyph on the taskbar/desktop. The squircle fills ~95% instead.
#
# Every paint after the base squircle is hard-clipped to the tile. Without
# the clip the sheen highlight bled a faint white haze past the tile edge
# (visible in the Dock against any colored background), and at small sizes
# the blur filter speckled near-zero-alpha garbage into the transparent
# margins — Windows taskbar/tray composites that as dirty specks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE}[0]")/.." && pwd)"
TOKENS="$ROOT/Assets/mubi/tokens.json"
OUT="$ROOT/Assets"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null && command -v rsvg-convert >/dev/null || {
  echo "need jq + rsvg-convert" >&2; exit 1; }

# ---- canonical geometry + colors (tokens.json is the single source) ----
BODY="$(jq -r '.geometry.body' "$TOKENS")"
FIN_L="$(jq -r '.geometry.finLeft' "$TOKENS")"
FIN_R="$(jq -r '.geometry.finRight' "$TOKENS")"
EYE_RX="$(jq -r '.geometry.eye.rx' "$TOKENS")"
EYE_RY="$(jq -r '.geometry.eye.ry' "$TOKENS")"
EYE_LX="$(jq -r '.geometry.eye.leftCx' "$TOKENS")"
EYE_RXC="$(jq -r '.geometry.eye.rightCx' "$TOKENS")"
EYE_CY="$(jq -r '.geometry.eye.cy' "$TOKENS")"
SH_CX="$(jq -r '.geometry.contactShadow.cx' "$TOKENS")"
SH_CY="$(jq -r '.geometry.contactShadow.cy' "$TOKENS")"
SH_RX="$(jq -r '.geometry.contactShadow.rx' "$TOKENS")"
SH_RY="$(jq -r '.geometry.contactShadow.ry' "$TOKENS")"
INK="$(jq -r '.colors["mubi.ink"]' "$TOKENS")"
FIN="$(jq -r '.colors["mubi.fin"]' "$TOKENS")"
BODY_LIGHT="$(jq -r '.colors["mubi.body.light"]' "$TOKENS")"
BODY_MID="$(jq -r '.colors["mubi.body"]' "$TOKENS")"
BODY_DEEP="$(jq -r '.colors["mubi.body.deep"]' "$TOKENS")"
SHADOW="$(jq -r '.colors["mubi.shadow"]' "$TOKENS")"
# The lower-form shade path is host-embedded master data (tokens.json does
# not carry it); same string as the Linux/Windows hosts embed.
LOWER_SHADE='M 16 96 C 24 118, 42 126, 60 126 C 80 126, 98 116, 105 94 C 100 116, 84 128, 60 128 C 38 128, 20 114, 16 96 Z'

# ---- compose the app icon: water-blue squircle, Mubi front and center ----
#
# emit_icon_svg OUT TILE_XY TILE_SIZE TILE_RX CHAR_SCALE CHAR_TX CHAR_TY
#                    SHEEN_CY SHEEN_RX SHEEN_RY
#
# CHAR_* and SHEEN_* are absolute canvas coordinates, scaled proportionally
# from the macOS grid values so both variants frame the character alike
# (the character sits low — icons read heavy at the bottom).
emit_icon_svg() {
  local out="$1" txy="$2" size="$3" rx="$4" scale="$5" ctx="$6" cty="$7" \
        scy="$8" srx="$9" sry="${10}"
  cat > "$out" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#8FCBFF"/>
      <stop offset="1" stop-color="#4FA7EE"/>
    </linearGradient>
    <linearGradient id="mubiBody" x1="0.18" y1="0.10" x2="0.78" y2="1.0">
      <stop offset="0" stop-color="$BODY_LIGHT"/>
      <stop offset="0.45" stop-color="$BODY_MID"/>
      <stop offset="1" stop-color="$BODY_DEEP"/>
    </linearGradient>
    <linearGradient id="lowerShade" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="$SHADOW" stop-opacity="0"/>
      <stop offset="1" stop-color="$SHADOW" stop-opacity="0.55"/>
    </linearGradient>
    <radialGradient id="sheen" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.09"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <filter id="soft" x="-60%" y="-60%" width="220%" height="220%">
      <feGaussianBlur stdDeviation="2.2"/>
    </filter>
    <clipPath id="tile">
      <rect x="$txy" y="$txy" width="$size" height="$size" rx="$rx"/>
    </clipPath>
  </defs>
  <rect x="$txy" y="$txy" width="$size" height="$size" rx="$rx" fill="url(#bg)"/>
  <g clip-path="url(#tile)">
    <ellipse cx="512" cy="$scy" rx="$srx" ry="$sry" fill="url(#sheen)"/>
    <rect x="$((txy + 1))" y="$((txy + 1))" width="$((size - 2))" height="$((size - 2))" rx="$((rx - 1))" fill="none"
          stroke="#FFFFFF" stroke-opacity="0.07" stroke-width="2"/>
    <g transform="translate($ctx $cty) scale($scale)">
      <ellipse cx="$SH_CX" cy="$SH_CY" rx="$SH_RX" ry="$SH_RY"
               fill="$SHADOW" opacity="0.5" filter="url(#soft)"/>
      <path d="$FIN_L" fill="$FIN"/>
      <path d="$FIN_R" fill="$FIN"/>
      <path d="$BODY" fill="url(#mubiBody)"/>
      <path d="$LOWER_SHADE" fill="url(#lowerShade)"/>
      <ellipse cx="$EYE_LX" cy="$EYE_CY" rx="$EYE_RX" ry="$EYE_RY" fill="$INK"/>
      <ellipse cx="$EYE_RXC" cy="$EYE_CY" rx="$EYE_RX" ry="$EYE_RY" fill="$INK"/>
    </g>
  </g>
</svg>
SVG
}

# macOS grid: 824 content on a 1024 canvas, ~184 corner radius, character
# at 4.6x translate(236 121).
emit_icon_svg "$TMP/icon-macos.svg" 100 824 184 4.6 236 121 150 560 420
# Dense grid: 976 content (95%), corner radius scaled 184 * 976/824 = 218,
# character at 4.6 * 976/824 = 5.45 translate(24 + 161  24 + 25) — offsets
# scaled from the macOS tile's (136, 21).
emit_icon_svg "$TMP/icon-dense.svg" 24 976 218 5.45 185 49 83 664 498

# ---- icns (macOS, Apple grid) ----
mkdir -p "$TMP/icon.iconset"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  set -- $spec
  rsvg-convert -w "$1" -h "$1" "$TMP/icon-macos.svg" -o "$TMP/icon.iconset/$2.png"
done
iconutil -c icns "$TMP/icon.iconset" -o "$OUT/movebit.icns"

# ---- ico (Windows: app + tray resource, dense tile) ----
python3 - "$TMP/icon-dense.svg" "$OUT/icon.ico" <<'PY'
import sys, subprocess, tempfile, os, struct
svg, out = sys.argv[1], sys.argv[2]
tmp = tempfile.mkdtemp()
sizes = [256, 128, 64, 48, 32, 16]
frames = []
for s in sizes:
    p = os.path.join(tmp, "%d.png" % s)
    subprocess.run(["rsvg-convert", "-w", str(s), "-h", str(s), svg, "-o", p], check=True)
    frames.append((s, open(p, "rb").read()))
# ICO container with PNG-compressed entries (valid at every size on Vista+):
# 6-byte header, 16-byte directory per frame, then the raw PNG payloads.
header = struct.pack("<HHH", 0, 1, len(frames))
dir_size = 6 + 16 * len(frames)
directory = b""
payload = b""
for s, blob in frames:
    directory += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32,
                             len(blob), dir_size + len(payload))
    payload += blob
with open(out, "wb") as f:
    f.write(header + directory + payload)
PY

# ---- png (Linux: AppImage/desktop entry, dense tile) ----
rsvg-convert -w 512 -h 512 "$TMP/icon-dense.svg" -o "$OUT/icon.png"

echo "app icons regenerated:"
ls -la "$OUT/movebit.icns" "$OUT/icon.ico" "$OUT/icon.png"
