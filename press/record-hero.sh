#!/bin/bash
# Records the LinkedIn "hero" GIF: branded background + faux menu bar with the
# reacting bell + the real toast sequence. Produces press/hero.gif (+ hero.mp4).
#
# Usage: bash press/record-hero.sh [it|en]
set -e
cd "$(dirname "$0")/.."

LANG_ARG="${1:-it}"
APP="build/ClaudeSessions.app/Contents/MacOS/ClaudeSessions"
OUT_DIR="press"
RAW="$OUT_DIR/hero-raw.mov"
GIF="$OUT_DIR/hero.gif"
MP4="$OUT_DIR/hero.mp4"

DURATION=8          # seconds of animation to capture
GIF_FPS=18
GIF_WIDTH=680       # output width in px (LinkedIn-friendly, retina-crisp)

[ -x "$APP" ] || { echo "Build first: bash build.sh"; exit 1; }

# The avfoundation "Capture screen 0" index is NOT stable (it shifts as iPhone
# Continuity cameras come and go), so resolve it fresh every run.
SCREEN_DEV="$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
  | sed -n 's/.*\[\([0-9]*\)\] Capture screen 0.*/\1/p' | head -1)"
[ -n "$SCREEN_DEV" ] || { echo "No 'Capture screen' avfoundation device found"; exit 1; }
echo "Screen device: $SCREEN_DEV"

# 1. Read the crop rectangle (retina px, top-left origin) from the app itself.
CROP_LINE="$("$APP" --hero-crop --lang="$LANG_ARG" 2>/dev/null | grep '^CROP')"
read -r _ CX CY CW CH <<< "$CROP_LINE"
[ -n "$CW" ] || { echo "Could not read crop rect"; exit 1; }
echo "Crop: ${CW}x${CH} @ ${CX},${CY}"

# 2. Launch the scene (its branded background covers the desktop instantly).
pkill -f "ClaudeSessions --demo-hero" 2>/dev/null || true
"$APP" --demo-hero --lang="$LANG_ARG" >/dev/null 2>&1 &
APP_PID=$!
sleep 1.0           # let the background + bell paint before recording

# 3. Record the full screen for the animation window.
ffmpeg -y -f avfoundation -capture_cursor 0 -framerate 30 -i "$SCREEN_DEV" \
       -t "$DURATION" -c:v libx264 -pix_fmt yuv420p "$RAW" 2>/dev/null

kill "$APP_PID" 2>/dev/null || true

# 4a. Crop + build an optimised, infinitely-looping GIF (two-pass palette).
ffmpeg -y -i "$RAW" -vf \
  "crop=${CW}:${CH}:${CX}:${CY},fps=${GIF_FPS},scale=${GIF_WIDTH}:-2:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3" \
  -loop 0 "$GIF" 2>/dev/null

# 4b. Also export a crisp MP4 (LinkedIn plays video better than GIF).
ffmpeg -y -i "$RAW" -vf \
  "crop=${CW}:${CH}:${CX}:${CY},scale=${GIF_WIDTH}:-2:flags=lanczos" \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$MP4" 2>/dev/null

rm -f "$RAW"
echo "Done:"
echo "  $GIF  ($(du -h "$GIF" | cut -f1))"
echo "  $MP4  ($(du -h "$MP4" | cut -f1))"
