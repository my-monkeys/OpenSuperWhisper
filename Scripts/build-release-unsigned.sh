#!/usr/bin/env bash
#
# Build the Release app the way notarize_app.sh does, without signing or notarizing it, so a
# change can go through Scripts/smoke-release.sh before a release and CI can build the Intel lane.
#
# Usage: Scripts/build-release-unsigned.sh <arm64|x86_64> [derived-data-dir]
#   derived-data-dir defaults to build-release/<arch>, and is deleted first so every run is a
#   clean build, as notarize_app.sh's is. The app lands in
#   <derived-data-dir>/Build/Products/Release/OpenSuperWhisper.app.
#
# Copied from notarize_app.sh, and to be kept in step with it: the forced native build, the
# autocorrect and onnxruntime staging, the xcodebuild flags and the x86_64 post-build edits. Swift
# packages are cloned inside the derived data, so FluidAudio is not patched, as in a release.
#
# build/ is left holding the universal autocorrect the project links from there, as
# notarize_app.sh leaves it; run.sh copies its own back. The core's xcframeworks in
# OpenSuperWhisperCore/Binaries are rebuilt for macOS only, so a later `Scripts/build-native.sh
# ios` or `all` builds the iOS slices again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-}"
DERIVED="${2:-build-release/$ARCH}"

case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "usage: $0 <arm64|x86_64> [derived-data-dir]" >&2; exit 2 ;;
esac
cd "$ROOT"
APP_PATH="$DERIVED/Build/Products/Release/OpenSuperWhisper.app"

echo "=== Building OpenSuperWhisper for $ARCH, unsigned, into $DERIVED ==="

./Scripts/fetch-sherpa.sh

mkdir -p build
# notarize_app.sh starts from an empty build/; this one keeps the dev build's derived data and
# only removes the dylibs it stages there, so none of the dev build's copies is linked by mistake.
rm -f build/libautocorrect_swift.dylib build/libonnxruntime*.dylib

# The core package's xcframeworks, always rebuilt from scratch, as for a release.
FORCE=1 ./Scripts/build-native.sh

# The dylibs are signed ad hoc where notarize_app.sh uses the Developer ID: an arm64 binary that
# install_name_tool has edited no longer loads without a signature.
if [ -f vendor/libautocorrect_swift.dylib ]; then
  echo "Using vendored prebuilt autocorrect-swift..."
  cp vendor/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
else
  echo "Building autocorrect-swift (universal)..."
  RUSTC_BIN="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc"
  (
    cd asian-autocorrect
    RUSTFLAGS="-C link-arg=-mmacosx-version-min=14.0" MACOSX_DEPLOYMENT_TARGET=14.0 RUSTC="$RUSTC_BIN" \
      "$HOME/.cargo/bin/cargo" build -p autocorrect-swift --release --target x86_64-apple-darwin
    RUSTFLAGS="-C link-arg=-mmacosx-version-min=14.0" MACOSX_DEPLOYMENT_TARGET=14.0 \
      cargo build -p autocorrect-swift --release --target aarch64-apple-darwin
  )
  lipo -create \
    ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib \
    ./asian-autocorrect/target/x86_64-apple-darwin/release/libautocorrect_swift.dylib \
    -output ./build/libautocorrect_swift.dylib
  install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
fi
codesign --force --sign - ./build/libautocorrect_swift.dylib

echo "Copying libonnxruntime.dylib..."
cp vendor/onnxruntime/libonnxruntime.1.24.4.dylib ./build/libonnxruntime.1.24.4.dylib
ln -sf libonnxruntime.1.24.4.dylib ./build/libonnxruntime.dylib
codesign --force --sign - ./build/libonnxruntime.1.24.4.dylib

rm -rf "$DERIVED"
# The two -skip flags only stop xcodebuild from asking to trust package plugins and macros, which
# a machine that never opened the project in Xcode (CI) cannot answer.
xcodebuild \
  -scheme "OpenSuperWhisper" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -skipMacroValidation \
  -quiet \
  build

if [ "$ARCH" = "x86_64" ]; then
  echo "x86_64: stripping arm64 onnxruntime + setting x86_64 appcast feed..."
  rm -f "$APP_PATH/Contents/Frameworks/libonnxruntime"*.dylib
  /usr/libexec/PlistBuddy -c \
    "Set :SUFeedURL https://raw.githubusercontent.com/my-monkeys/OpenSuperWhisper/master/appcast-x86_64.xml" \
    "$APP_PATH/Contents/Info.plist"
fi

echo "Built $APP_PATH"
