#!/usr/bin/env bash
#
# Smoke check of a Release OpenSuperWhisper.app, optionally against a recorded report.
#
# Usage: Scripts/smoke-release.sh <path/to/OpenSuperWhisper.app> [--arch arm64|x86_64]
#                                 [--expect <file>] [--record <file>]
#
# Runs the app's CLI on jfk.wav, and on jfk.wav with 3 s of digital silence on each side, with
# `--model ggml-tiny.en.bin --raw` so nothing configured on this Mac can change the input. Each
# clip runs twice: from the bundle, and through a symlink in an empty directory, the way
# Homebrew runs it, where Bundle.main has no resources and the VAD model is only found through
# the engine's own bundle. x86_64 runs under Rosetta. --arch defaults to the binary's only slice.
#
# Refuses to run while the app's "Unload model when idle" setting is on (see below). Fails when a
# run exits non-zero or its stderr lacks whisper.cpp's "loading VAD model" line for
# this app's Contents/Resources/ggml-silero-v5.1.2.bin; when an arm64 run does not use Metal;
# when the VAD model is missing from Contents/Resources; when _whisper_full or
# _ggml_backend_metal_reg is not defined exactly once across the app's binaries; when
# onnxruntime is missing on arm64 or present on x86_64 (linked, embedded or referenced); and when
# a signed app fails `codesign --verify --deep --strict` (an unsigned one is skipped with a note).
#
# Prints a report of what it saw: transcripts, VAD segments, load commands, rpaths, embedded
# frameworks, libomp and onnxruntime, symbol counts, the toolchain that built the app. It holds
# no path or machine name, but transcripts and VAD segments depend on the CPU and GPU, so only
# compare reports made on the same Mac. --record writes it; --expect diffs it against a recorded
# one and fails on any difference.
#
# Intended differences from the pre-swap references (docs/core-extraction.md, slice 0): slice 2
# drops libomp, which removes the @rpath/libomp.dylib load command, libomp.dylib from the
# frameworks line, and turns the libomp line into "linked no, embedded no". Nothing else may move.
# From slice 2 on, compare against docs/smoke/post-swap-<arch>.txt, where nothing may move at all.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="$ROOT/ggml-tiny.en.bin"
CLIP="$ROOT/jfk.wav"
VAD_MODEL="ggml-silero-v5.1.2.bin"
PADDING_SECONDS=3

usage() { echo "usage: $0 <path/to/OpenSuperWhisper.app> [--arch arm64|x86_64] [--expect <file>] [--record <file>]" >&2; exit 2; }
fail() { echo "smoke-release: error: $*" >&2; exit 1; }

APP="" ARCH="" EXPECT="" RECORD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)   [[ $# -ge 2 ]] || usage; ARCH="$2"; shift 2 ;;
    --expect) [[ $# -ge 2 ]] || usage; EXPECT="$2"; shift 2 ;;
    --record) [[ $# -ge 2 ]] || usage; RECORD="$2"; shift 2 ;;
    -*)       usage ;;
    *)        [[ -z "$APP" ]] || usage; APP="$1"; shift ;;
  esac
done
[[ -n "$APP" ]] || usage
[[ -d "$APP" ]] || fail "not an app bundle: $APP"
APP="$(cd "$APP" && pwd -P)"
EXE="$APP/Contents/MacOS/OpenSuperWhisper"
[[ -x "$EXE" ]] || fail "no executable at $EXE"
[[ -f "$MODEL" && -f "$CLIP" ]] || fail "$MODEL and $CLIP are needed (tracked in the repo)"
[[ -z "$EXPECT" || -f "$EXPECT" ]] || fail "no expectation file at $EXPECT"

SLICES="$(lipo -archs "$EXE")"
if [[ -z "$ARCH" ]]; then
  [[ "$SLICES" != *" "* ]] || fail "the binary has several slices ($SLICES); pass --arch"
  ARCH="$SLICES"
fi
case "$ARCH" in arm64|x86_64) ;; *) usage ;; esac
[[ " $SLICES " == *" $ARCH "* ]] || fail "the binary has no $ARCH slice (it has: $SLICES)"

# The exit-code check is what catches a ggml without the fork's Metal teardown fix, which aborts
# in exit() while a whisper context is alive. WhisperEngine reads this preference even under
# --model --raw, and with it on the context is already freed when the CLI exits.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
case "$(defaults read "$BUNDLE_ID" unloadWhisperModelWhenIdle 2>/dev/null || true)" in
  1|true|YES) fail "Whisper's \"Unload model when idle\" is on in $BUNDLE_ID's settings: the CLI would exit with no context loaded and prove nothing. Turn it off for the check." ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPORT="$WORK/report.txt"
FAILURES=0

report() { echo "$*" >> "$REPORT"; }
problem() { echo "smoke-release: FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

# --- Inputs -------------------------------------------------------------------------------------

le_bytes() {  # value, byte count: the value as little-endian bytes on stdout
  local value=$1 count=$2 i
  for ((i = 0; i < count; i++)); do
    printf "\\$(printf %03o $(((value >> (8 * i)) & 255)))"
  done
}

# jfk.wav with PADDING_SECONDS of zeros before and after, as a canonical 44-byte-header WAV. Built
# from the bytes of the clip so it is identical on every Mac, with no tool beyond the base system.
make_padded_clip() {
  local out=$1 offset=12 id size
  afinfo "$CLIP" | grep -q "1 ch,  16000 Hz, Int16" || fail "$CLIP is no longer 16 kHz mono Int16"
  while :; do
    id="$(dd if="$CLIP" bs=1 skip=$offset count=4 2>/dev/null)"
    size=$(od -An -t u4 -j $((offset + 4)) -N 4 "$CLIP" | tr -d ' ')
    [[ -n "$size" ]] || fail "no data chunk in $CLIP"
    [[ "$id" == "data" ]] && break
    offset=$((offset + 8 + size + size % 2))
  done
  local pad=$((PADDING_SECONDS * 16000 * 2))
  local data=$((pad + size + pad))
  {
    printf 'RIFF'; le_bytes $((36 + data)) 4; printf 'WAVEfmt '
    le_bytes 16 4; le_bytes 1 2; le_bytes 1 2; le_bytes 16000 4; le_bytes 32000 4
    le_bytes 2 2; le_bytes 16 2
    printf 'data'; le_bytes $data 4
    head -c $pad /dev/zero
    tail -c +$((offset + 9)) "$CLIP" | head -c "$size"
    head -c $pad /dev/zero
  } > "$out"
}

PADDED="$WORK/jfk-padded.wav"
make_padded_clip "$PADDED"

# --- Runs ---------------------------------------------------------------------------------------

# A symlink in a directory of its own, like /opt/homebrew/bin/opensuperwhisper.
LINK_DIR="$WORK/bin"
mkdir "$LINK_DIR"
ln -s "$EXE" "$LINK_DIR/opensuperwhisper"

run_cli() {  # name, launcher, clip
  local name=$1 launcher=$2 clip=$3 status=0 before=$FAILURES
  local out="$WORK/${name//\//-}.out" err="$WORK/${name//\//-}.err"
  # Release builds link clang's profile runtime (see the coverage follow-up in
  # docs/core-extraction.md), which would leave a default.profraw in the caller's directory.
  LLVM_PROFILE_FILE="$WORK/profile-%p.profraw" \
    arch "-$ARCH" "$launcher" transcribe "$clip" --model "$MODEL" --raw > "$out" 2> "$err" || status=$?
  report "run $name: exit $status"
  [[ $status -eq 0 ]] || problem "$name exited with $status"
  report "run $name: text $(tr '\n' ' ' < "$out" | sed -E 's/^ +//; s/ +$//')"

  local vad
  vad="$(sed -nE "s/^.*: loading VAD model from '(.*)'$/\1/p" "$err" | sed -n 1p)"
  if [[ "$vad" == "$APP/Contents/Resources/$VAD_MODEL" ]]; then
    report "run $name: vad model <app>/Contents/Resources/$VAD_MODEL"
  else
    report "run $name: vad model ${vad:-not loaded}"
    problem "$name did not load the VAD model from the app's Contents/Resources (got: ${vad:-nothing})"
  fi
  report "run $name: vad segments $(sed -nE 's/^.*VAD segment [0-9]+: start = ([0-9.]+), end = ([0-9.]+).*$/\1-\2/p' "$err" | tr '\n' ' ' | sed -E 's/ +$//')"

  if grep -qE "^whisper_backend_init_gpu: using MTL[0-9]+ backend" "$err" && grep -q "^ggml_metal_init: allocating" "$err"; then
    report "run $name: metal yes"
  else
    report "run $name: metal no"
    [[ "$ARCH" != "arm64" ]] || problem "$name did not initialise ggml's Metal backend"
  fi
  if [[ $FAILURES -ne $before ]]; then
    echo "smoke-release: end of the stderr of $name:" >&2
    tail -n 30 "$err" | sed 's/^/  | /' >&2
  fi
}

report "# Scripts/smoke-release.sh report"
report "arch: $ARCH"
report "toolchain: Xcode $(/usr/libexec/PlistBuddy -c 'Print :DTXcodeBuild' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown), SDK $(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
run_cli jfk/app "$EXE" "$CLIP"
run_cli jfk/symlink "$LINK_DIR/opensuperwhisper" "$CLIP"
run_cli padded/app "$EXE" "$PADDED"
run_cli padded/symlink "$LINK_DIR/opensuperwhisper" "$PADDED"

# --- The bundle ---------------------------------------------------------------------------------

# Captured once: grep -q on a pipe would stop reading early, and pipefail would count the writer's
# SIGPIPE as a failure.
LOADS="$(otool -arch "$ARCH" -L "$EXE")"
UNDEFINED="$(nm -arch "$ARCH" -u "$EXE")"
tail -n +2 <<< "$LOADS" | sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//' | LC_ALL=C sort \
  | while read -r dylib; do report "load: $dylib"; done
otool -arch "$ARCH" -l "$EXE" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' \
  | while read -r rpath; do report "rpath: $rpath"; done

FRAMEWORKS="$APP/Contents/Frameworks"
report "frameworks: $( (LC_ALL=C ls "$FRAMEWORKS" 2>/dev/null || true) | tr '\n' ' ' | sed -E 's/ +$//')"

linked() { grep -q "$1" <<< "$LOADS" && echo yes || echo no; }
embedded() { compgen -G "$FRAMEWORKS/$1" > /dev/null && echo yes || echo no; }
report "libomp: linked $(linked libomp), embedded $(embedded 'libomp*.dylib')"
ORT_LINKED="$(linked libonnxruntime)"
ORT_EMBEDDED="$(embedded 'libonnxruntime*.dylib')"
ORT_REFERENCED="$(grep -q '_OrtGetApiBase$' <<< "$UNDEFINED" && echo yes || echo no)"
report "onnxruntime: linked $ORT_LINKED, embedded $ORT_EMBEDDED, _OrtGetApiBase undefined $ORT_REFERENCED"
if [[ "$ARCH" == "arm64" ]]; then
  [[ "$ORT_LINKED $ORT_EMBEDDED" == "yes yes" ]] || problem "arm64 must link and embed onnxruntime (SenseVoice)"
else
  [[ "$ORT_LINKED $ORT_EMBEDDED $ORT_REFERENCED" == "no no no" ]] \
    || problem "x86_64 must neither link, embed nor reference onnxruntime: it is arm64 only"
fi

# Every Mach-O in the bundle, so a second copy of whisper or ggml in a dylib is counted too.
MACHOS="$WORK/machos.txt"
find "$APP/Contents" -type f -print0 | while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q "Mach-O"; then echo "$file"; fi
done > "$MACHOS"
for symbol in _whisper_full _ggml_backend_metal_reg; do
  count=0
  while IFS= read -r file; do
    n=$( (nm -arch "$ARCH" --defined-only -m "$file" 2>/dev/null || true) | grep -cE " ${symbol}\$" || true)
    count=$((count + n))
  done < "$MACHOS"
  report "defined $symbol: $count"
  [[ $count -eq 1 ]] || problem "$symbol is defined $count times across the bundle, expected exactly once"
done

if [[ -f "$APP/Contents/Resources/$VAD_MODEL" ]]; then
  report "resource $VAD_MODEL: present"
else
  report "resource $VAD_MODEL: missing"
  problem "Contents/Resources/$VAD_MODEL is missing"
fi

# Not in the report: the references are built unsigned, and the shipped app is signed.
if [[ -f "$APP/Contents/_CodeSignature/CodeResources" ]]; then
  if codesign --verify --deep --strict "$APP"; then
    echo "smoke-release: signature valid"
  else
    problem "codesign --verify --deep --strict failed"
  fi
else
  echo "smoke-release: note: the app is not signed, signature check skipped"
fi

# --- Verdict ------------------------------------------------------------------------------------

cat "$REPORT"
if [[ -n "$EXPECT" ]] && ! diff -u --label "expected ($EXPECT)" --label "this app" "$EXPECT" "$REPORT"; then
  problem "the report differs from $EXPECT (lines marked - are expected, + are what this app gave)"
fi
[[ $FAILURES -eq 0 ]] || fail "$FAILURES check(s) failed, nothing recorded"
if [[ -n "$RECORD" ]]; then
  cp "$REPORT" "$RECORD"
  echo "smoke-release: recorded $RECORD"
fi
echo "smoke-release: OK ($ARCH)"
