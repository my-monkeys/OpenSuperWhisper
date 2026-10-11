#!/usr/bin/env bash
#
# Fetch the prebuilt sherpa-onnx static xcframework + the onnxruntime dylib into vendor/.
# These power the SenseVoice engine. They are gitignored (76 MB of binaries); this script
# downloads them on demand. Called by run.sh and notarize_app.sh before building.
#
# Each archive is downloaded into a private temporary directory and must match its pinned
# SHA-256 before anything is extracted: these binaries are linked into the shipped app. A version
# bump updates the two hashes with it (shasum -a 256 on the new archives).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
SHERPA_VER="1.13.3"
ORT_VER="1.24.4"
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VER}"
XCF_ARCHIVE="sherpa-onnx-v${SHERPA_VER}-macos-xcframework-static.tar.bz2"
XCF_SHA256="e1dcd71368ce7dba20622c75f8bdd1a2d2eda4265ce4a1be4a1ac3a2fc74dc9a"
ORT_ARCHIVE="sherpa-onnx-v${SHERPA_VER}-onnxruntime-${ORT_VER}-osx-arm64-shared.tar.bz2"
ORT_SHA256="dc101812665f9c6a68b8256fa80baf201795b572ea213d5b08735d2cedf9cc22"
mkdir -p "$VENDOR"

TMP=""
trap '[ -z "$TMP" ] || rm -rf "$TMP"' EXIT

# Downloads $1 into $TMP and extracts it into $TMP/x once its SHA-256 matches $2.
fetch_verified() {
  local archive=$1 expected=$2 actual
  TMP="$(mktemp -d)"
  curl -fsSL "${BASE}/${archive}" -o "$TMP/$archive"
  actual="$(shasum -a 256 "$TMP/$archive" | cut -d' ' -f1)"
  if [ "$actual" != "$expected" ]; then
    echo "fetch-sherpa: error: $archive has SHA-256 $actual, expected $expected" >&2
    exit 1
  fi
  mkdir "$TMP/x"
  tar xf "$TMP/$archive" -C "$TMP/x"
}

if [ ! -d "$VENDOR/sherpa-onnx.xcframework" ]; then
  echo "Fetching sherpa-onnx.xcframework v${SHERPA_VER}…"
  fetch_verified "$XCF_ARCHIVE" "$XCF_SHA256"
  mv "$TMP"/x/*/sherpa-onnx.xcframework "$VENDOR/sherpa-onnx.xcframework"
  rm -rf "$TMP"; TMP=""
fi

if [ ! -f "$VENDOR/onnxruntime/libonnxruntime.${ORT_VER}.dylib" ]; then
  echo "Fetching onnxruntime ${ORT_VER} dylib…"
  fetch_verified "$ORT_ARCHIVE" "$ORT_SHA256"
  mkdir -p "$VENDOR/onnxruntime"
  cp "$TMP"/x/*/lib/libonnxruntime.${ORT_VER}.dylib "$VENDOR/onnxruntime/"
  ln -sf "libonnxruntime.${ORT_VER}.dylib" "$VENDOR/onnxruntime/libonnxruntime.dylib"
  rm -rf "$TMP"; TMP=""
fi

echo "sherpa-onnx vendored in vendor/."
