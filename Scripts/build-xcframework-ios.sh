#!/usr/bin/env bash
#
# build-xcframework-ios.sh — build the genuinely-static whisper.xcframework for iOS
# (device arm64 + simulator arm64) from the pinned whisper.cpp submodule.
#
# Adapted from upstream whisper.cpp v1.9.1's build-xcframework.sh, TRIMMED to the two
# iOS slices (lead ruling 2026-07-20: no macOS/visionOS/tvOS paths, no CoreML entry —
# every line load-bearing; upstream drift is assessed at the next submodule bump, not
# carried as dead code). Static packaging reproduces upstream's
# BUILD_STATIC_XCFRAMEWORK=ON semantics: per slice the six static archives are
# libtool-combined and placed as the framework bundle's binary (a STATIC framework —
# consumers link statically, nothing is embedded), then packaged with
# `xcodebuild -create-xcframework -framework`.
#
# Flag contract (docs/plans/ios-companion-foundation-plan.md, Build Script Spec;
# configure-probed EXIT=0 at v1.9.1 on both slices):
#   GGML_METAL=ON GGML_METAL_EMBED_LIBRARY=ON  — Metal shaders embedded as SOURCE via
#     .incbin (runtime-compiled; no .metallib file dependency)
#   GGML_OPENMP=OFF                            — no libomp on iOS
#   GGML_NATIVE=OFF                            — portable binaries
#   WHISPER_COREML=OFF                         — unused by the app; drops
#     libwhisper.coreml.a from the combine list (upstream's script hardcodes it)
#   GGML_CPU_ARM_ARCH="armv8.2-a+dotprod+fp16" — the iOS target compiler defaults to
#     baseline FMA only; every iOS 17 device is A12+. Without this the CPU backend
#     silently loses dotprod/fp16 (probe-discovered; the old pin's "enabled" message
#     read HOST compiler defaults — a cross-build false positive)
#   -DGGML_MATMUL_INT8=0 -U__ARM_FEATURE_MATMUL_INT8 — the fork's i8mm workaround,
#     KEPT as defense-in-depth: upstream's -U fallback covers detection-FAILURE only,
#     not the fork's detection-passes-compile-fails CI incident mode (#25 finding)
#   min iOS 17.0 (upstream default 16.4 — overridden to the plan's deployment target)
#
# Output: build/whisper-ios.xcframework, with Modules/module.modulemap exposing clang
# module `whisper` (HARD CONTRACT: Swift framework targets cannot use bridging
# headers — WhisperCore consumes whisper as a module).
#
# Fail-loud: every combine archive and header is existence-checked with the expected
# list printed — a whisper.cpp bump that adds/renames a backend archive must break
# loudly here, never silently drop a backend (same philosophy as the FluidAudio patch).
#
# Builds OUTSIDE the submodule (-B build/ios-xcf/<slice> -S libwhisper/whisper.cpp) so
# the submodule working tree stays clean. Re-runs are idempotent: prior outputs are
# removed first. Build artifacts live under build/ (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/libwhisper/whisper.cpp"
BUILD_ROOT="$ROOT/build/ios-xcf"
XCF_OUT="$ROOT/build/whisper-ios.xcframework"
IOS_MIN="17.0"

for tool in cmake xcodebuild libtool; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required but not found." >&2; exit 1; }
done
[[ -d "$SRC/src" ]] || { echo "error: whisper.cpp submodule not checked out at $SRC" >&2; exit 1; }

# i8mm workaround rides the C/CXX flags (see header comment).
I8MM_FLAGS="-DGGML_MATMUL_INT8=0 -U__ARM_FEATURE_MATMUL_INT8"

COMMON_CMAKE_ARGS=(
  -DBUILD_SHARED_LIBS=OFF
  -DWHISPER_BUILD_EXAMPLES=OFF
  -DWHISPER_BUILD_TESTS=OFF
  -DWHISPER_BUILD_SERVER=OFF
  -DWHISPER_COREML=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_OPENMP=OFF
  -DGGML_NATIVE=OFF
  -DGGML_CPU_ARM_ARCH="armv8.2-a+dotprod+fp16"
  -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN}
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
  -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT="dwarf-with-dsym"
  -DCMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP=NO
  -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO
  -DCMAKE_C_FLAGS="${I8MM_FLAGS}"
  -DCMAKE_CXX_FLAGS="${I8MM_FLAGS}"
)

# configure_and_build <build-dir-name> <sysroot> [extra cmake args...]
configure_and_build() {
  local build_dir="$1" sysroot="$2"
  shift 2
  echo "=== Configuring $build_dir ($sysroot) ==="
  cmake -B "$BUILD_ROOT/$build_dir" -G Xcode -S "$SRC" \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="$sysroot" \
    "$@"
  echo "=== Building $build_dir (Release) ==="
  cmake --build "$BUILD_ROOT/$build_dir" --config Release -- -quiet
}

# make_static_framework <build-dir-name> <release-subdir>
# Reproduces upstream's flat iOS framework layout; the bundle's "binary" is the
# libtool-combined STATIC archive.
make_static_framework() {
  local build_dir="$1" rel="$2"
  local bd="$BUILD_ROOT/$build_dir"
  local fw="$bd/framework/whisper.framework"

  rm -rf "$fw"
  mkdir -p "$fw/Headers" "$fw/Modules"

  local headers=(whisper.h ggml.h ggml-alloc.h ggml-backend.h ggml-metal.h ggml-cpu.h ggml-blas.h gguf.h)
  local h src_h
  for h in "${headers[@]}"; do
    if [[ "$h" == "whisper.h" ]]; then src_h="$SRC/include/$h"; else src_h="$SRC/ggml/include/$h"; fi
    [[ -f "$src_h" ]] || { echo "error: expected header missing: $src_h" >&2; exit 1; }
    cp "$src_h" "$fw/Headers/"
  done

  cat > "$fw/Modules/module.modulemap" << 'EOF'
framework module whisper {
    header "whisper.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
EOF

  cat > "$fw/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>whisper</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.whisper</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>whisper</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${IOS_MIN}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>iPhoneOS</string>
    </array>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>DTPlatformName</key>
    <string>iphoneos</string>
    <key>DTSDKName</key>
    <string>iphoneos${IOS_MIN}</string>
</dict>
</plist>
EOF

  # Expected archive set with WHISPER_COREML=OFF (no libwhisper.coreml.a). A whisper.cpp
  # bump that adds/renames a backend MUST fail here — never silently drop one.
  local libs=(
    "$bd/src/$rel/libwhisper.a"
    "$bd/ggml/src/$rel/libggml.a"
    "$bd/ggml/src/$rel/libggml-base.a"
    "$bd/ggml/src/$rel/libggml-cpu.a"
    "$bd/ggml/src/ggml-metal/$rel/libggml-metal.a"
    "$bd/ggml/src/ggml-blas/$rel/libggml-blas.a"
  )
  local missing=0 lib
  for lib in "${libs[@]}"; do
    [[ -f "$lib" ]] || { echo "error: missing expected archive: $lib" >&2; missing=1; }
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "Expected 6 archives: libwhisper libggml libggml-base libggml-cpu libggml-metal libggml-blas." >&2
    echo "A whisper.cpp bump may have added/renamed a backend — reconcile this list with the new source." >&2
    exit 1
  fi

  # Multi-arch libtool notes are irrelevant here (single-arch slices); keep output quiet.
  libtool -static -o "$bd/combined.a" "${libs[@]}" 2>/dev/null
  cp "$bd/combined.a" "$fw/whisper"
}

echo "Cleaning previous outputs..."
rm -rf "$BUILD_ROOT" "$XCF_OUT"
mkdir -p "$BUILD_ROOT" "$(dirname "$XCF_OUT")"

configure_and_build "ios-device" "iphoneos"
configure_and_build "ios-sim" "iphonesimulator" -DIOS=ON

make_static_framework "ios-device" "Release-iphoneos"
make_static_framework "ios-sim" "Release-iphonesimulator"

echo "=== Creating $XCF_OUT ==="
xcodebuild -create-xcframework \
  -framework "$BUILD_ROOT/ios-device/framework/whisper.framework" \
  -framework "$BUILD_ROOT/ios-sim/framework/whisper.framework" \
  -output "$XCF_OUT"

echo "Built static $XCF_OUT (ios-arm64 device + ios-arm64 simulator, min iOS ${IOS_MIN})."
