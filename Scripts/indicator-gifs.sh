#!/bin/bash
# Records the Liquid Glass recording indicator through a whole dictation and cuts it into the GIFs
# used in pull requests and docs.
#
#   Scripts/indicator-gifs.sh [output-dir]      (default: docs/liquid-glass)
#
# Needs a Debug build of the app (the capture probe is DEBUG-only) and ffmpeg on the PATH
# (`nix shell nixpkgs#ffmpeg`, or `brew install ffmpeg`). Build first, e.g.:
#
#   xcodebuild -scheme OpenSuperWhisper -configuration Debug -derivedDataPath build \
#     -destination platform=macOS,arch=arm64 build
#
# How it works: `OpenSuperWhisper indicator-live <dir>` with PROBE_GIF=<night|day|busy> drives the
# REAL indicator (IndicatorGIFProbe.swift) over a stand-in desktop, stages the waveform and (with
# PROBE_LIVE=1) a live caption — no microphone, no transcription — and screen-records it with an
# events.txt of when each step happened. This script then cuts those recordings into scenes.
#
# The probe reads the indicator settings from the app's defaults, so this script pins a complete
# layout (dot, label, waveform, Stop, Cancel), the "top" position and the Liquid Glass theme for
# the run and restores your own values afterwards, however it exits. The screen must stay awake
# and uncovered while it records (about a minute).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/docs/liquid-glass}
APP=${APP:-$ROOT/build/Build/Products/Debug/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper}
DOMAIN=fr.my-monkey.opensuperwhisper
WORK=$(mktemp -d)

[ -x "$APP" ] || { echo "No Debug build at $APP (set APP=… or build first)"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (nix shell nixpkgs#ffmpeg, or brew install ffmpeg)"; exit 1; }

# MARK: - Pin the settings the probe reads, restore them on exit

read_pref() { defaults read "$DOMAIN" "$1" 2>/dev/null || echo "__UNSET__"; }
restore_pref() {
  if [ "$2" = "__UNSET__" ]; then defaults delete "$DOMAIN" "$1" 2>/dev/null || true
  else defaults write "$DOMAIN" "$1" -string "$2"; fi
}
OLD_POSITION=$(read_pref indicatorPosition)
OLD_LAYOUT=$(read_pref indicatorLayout)
OLD_THEME=$(read_pref uiTheme)
cleanup() {
  restore_pref indicatorPosition "$OLD_POSITION"
  restore_pref indicatorLayout "$OLD_LAYOUT"
  restore_pref uiTheme "$OLD_THEME"
  rm -rf "$WORK"
}
trap cleanup EXIT

defaults write "$DOMAIN" indicatorPosition -string top
defaults write "$DOMAIN" uiTheme -string liquidGlass
defaults write "$DOMAIN" indicatorLayout -string \
  '{"waveformHeight":30,"order":["dot","label","waveform","stopButton","cancelButton"],"hidden":[]}'

# A running copy of the app would show its own bubble on top of the probe's.
pkill -x OpenSuperWhisper 2>/dev/null || true

# MARK: - Record

# capture <wallpaper> <normal|live>
capture() {
  local dir=$WORK/$1-$2
  mkdir -p "$dir"
  echo "Recording $1 ($2)…"
  if [ "$2" = live ]; then
    PROBE_GIF=$1 PROBE_LIVE=1 "$APP" indicator-live "$dir" >/dev/null 2>&1
  else
    PROBE_GIF=$1 "$APP" indicator-live "$dir" >/dev/null 2>&1
  fi
  [ -s "$dir/capture.mov" ] || { echo "No recording for $1-$2"; exit 1; }
}
capture night normal
capture day normal
capture busy normal
capture night live

# MARK: - Cut

mkdir -p "$OUT"
# event <capture> <name>: seconds into the recording at which the probe did <name>
event() { awk -v k="$2" '$2==k {print $1}' "$WORK/$1/events.txt"; }
calc() { awk "BEGIN { printf \"%.2f\", $1 }"; }

# gif <capture> <name> <start> <end> <width> <fps>
# Crops to the strip the bubble lives in (so nothing else on screen can end up in the GIF), then
# a two-pass palette for clean glass gradients.
gif() {
  local duration
  duration=$(calc "$4 - $3")
  ffmpeg -loglevel error -y -ss "$3" -t "$duration" -i "$WORK/$1/capture.mov" \
    -vf "crop=in_w:trunc(in_h*0.72/2)*2:0:0,fps=$6,scale=$5:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    "$OUT/$2.gif"
  printf "  %-34s %5ss %5s KB\n" "$2.gif" "$duration" "$(( $(stat -f %z "$OUT/$2.gif") / 1024 ))"
}

echo "Writing GIFs to $OUT"
c=night-normal
gif $c 1-appear-and-emerge         "$(calc "$(event $c show) - 0.2")"  "$(calc "$(event $c show) + 1.9")"   660 30
gif $c 2-stop-transcribe-done      "$(calc "$(event $c stop) - 0.4")"  "$(calc "$(event $c hide) + 1.0")"   660 30
gif $c 3-cancel                    "$(calc "$(event $c show2) - 0.2")" "$(calc "$(event $c cancel) + 1.2")" 660 30
c=night-live
gif $c 4-live-caption              "$(calc "$(event $c caption) - 0.3")" "$(calc "$(event $c stop) - 0.05")" 660 30
gif $c 5-live-stop-transcribe-done "$(calc "$(event $c stop) - 0.4")"  "$(calc "$(event $c hide) + 1.0")"   660 30
for c in night-normal day-normal busy-normal night-live; do
  gif $c "dictation-$c" "$(calc "$(event $c show) - 0.2")" "$(calc "$(event $c hide) + 1.0")" 560 20
done
