#!/usr/bin/env bash
#
# Build the native libraries of the core package as static xcframeworks in
# OpenSuperWhisperCore/Binaries/ (gitignored, and outside build/, which the release scripts delete):
#
#   OSWNative.xcframework   whisper + llama + their single shared ggml, from ONE configure of
#                           libwhisper/ per slice, archives merged with `libtool -static`
#   SherpaOnnx.xcframework  the vendored macOS sherpa-onnx library, its module map moved to
#                           Headers/sherpa_onnx/ so Xcode finds it (it ignores Modules/ for libraries)
#
# Usage: Scripts/build-native.sh [macos|ios|all]    (default: macos)
#   macos  arm64 + x86_64, macOS 14.0, generic ggml CPU kernels: notarize_app.sh's configure
#   ios    iOS arm64 and iOS Simulator arm64, iOS 17.0
#
# A stamp of every input that changes the binaries (submodule SHAs and uncommitted changes,
# libwhisper/CMakeLists.txt, this script, the toolchain, the configure arguments, the vendored
# sherpa library) is kept next to the outputs; when it matches and the slices asked for are
# already built, nothing happens. FORCE=1 rebuilds every requested slice from a clean configure.
#
# Merging uses `libtool -static`, never `ld -r` or a master object: the whisper and llama
# symbols are private externs (-fvisibility=hidden) and would become locals.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/$(basename "$0")"
SRC="$ROOT/libwhisper"
WORK="$ROOT/build-native"
OUT="$ROOT/OpenSuperWhisperCore/Binaries"
STAMP="$OUT/.stamp"
SHERPA="$ROOT/vendor/sherpa-onnx.xcframework/macos-arm64_x86_64"
FORCE="${FORCE:-0}"

case "${1:-macos}" in
  macos) REQUESTED="macos" ;;
  ios)   REQUESTED="ios iossim" ;;
  all)   REQUESTED="macos ios iossim" ;;
  *)     echo "usage: $0 [macos|ios|all]" >&2; exit 2 ;;
esac

ALL_SLICES="macos ios iossim"
# Every archive `whisper` and `llama` pull in. A submodule bump that adds a backend must fail
# here rather than ship a library with a backend missing.
ARCHIVES="ggml ggml-base ggml-blas ggml-cpu ggml-metal llama whisper"
# The C headers of the module and everything they include. ggml-cpp.h is C++ only.
HEADERS="whisper.cpp/include/whisper.h llama.cpp/include/llama.h
  whisper.cpp/ggml/include/ggml.h whisper.cpp/ggml/include/ggml-alloc.h
  whisper.cpp/ggml/include/ggml-backend.h whisper.cpp/ggml/include/ggml-cpu.h
  whisper.cpp/ggml/include/ggml-metal.h whisper.cpp/ggml/include/ggml-blas.h
  whisper.cpp/ggml/include/ggml-opt.h whisper.cpp/ggml/include/gguf.h"

log() { echo "==> build-native: $*"; }
fail() { echo "build-native: error: $*" >&2; exit 1; }

for tool in cmake xcodebuild libtool lipo otool nm git shasum; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[[ -f "$SRC/whisper.cpp/CMakeLists.txt" && -f "$SRC/llama.cpp/CMakeLists.txt" ]] \
  || fail "libwhisper submodules are not checked out (git submodule update --init --recursive)"

# Sets ARGS to the configure arguments of a slice. GGML_METAL and GGML_METAL_EMBED_LIBRARY are
# already the defaults on Apple platforms; they are spelled out because the app depends on them.
slice_args() {
  ARGS=(-G Xcode -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
  case "$1" in
    macos)
      ARGS+=("-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0) ;;
    ios|iossim)
      local sdk=iphoneos
      [[ "$1" == iossim ]] && sdk=iphonesimulator
      # No GGML_CPU_ARM_ARCH: ggml picks its CPU kernels at compile time, and the oldest iOS 17
      # devices lack dot product (A12) and fp16 vector arithmetic (the A10 iPads of iPadOS 17).
      # Static try-compiles because an iOS executable cannot be linked without signing.
      ARGS+=(-DCMAKE_SYSTEM_NAME=iOS "-DCMAKE_OSX_SYSROOT=$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64
             -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
             "-DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=$sdk"
             -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO) ;;
  esac
}

# Dot product, int8 matrix multiply and fp16 vector arithmetic in otool's Apple syntax (`sdot.4s`,
# `fmla.8h`); fcvtn to half precision is baseline. None may appear in the iOS device slice
# (slice_args). The simulator compiler targets Apple silicon Macs, which all have them.
BEYOND_ARMV8_0='[[:space:]]((s|u|us)(dot|mmla)[.[:space:]]|f[a-z0-9]+\.[48]h[[:space:]])'
ARMV8_0_HALF='[[:space:]]fcvtn2?\.[48]h[[:space:]]'

# Expected architectures, LC_BUILD_VERSION platform and minimum OS of a slice.
slice_expect() {
  case "$1" in
    macos)  EXPECT_ARCHS="arm64 x86_64"; EXPECT_PLATFORM=1; EXPECT_MINOS=14.0 ;;
    ios)    EXPECT_ARCHS="arm64";        EXPECT_PLATFORM=2; EXPECT_MINOS=17.0 ;;
    iossim) EXPECT_ARCHS="arm64";        EXPECT_PLATFORM=7; EXPECT_MINOS=17.0 ;;
  esac
}

contains() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

submodule_state() {
  git -C "$1" rev-parse HEAD
  git -C "$1" diff HEAD --binary
  git -C "$1" ls-files --others --exclude-standard
  git -C "$1" ls-files --others --exclude-standard | git -C "$1" hash-object --stdin-paths
}

toolchain() { xcodebuild -version; cmake --version; }

stamp_inputs() {
  shasum -a 256 "$SCRIPT" "$SRC/CMakeLists.txt"
  submodule_state "$SRC/whisper.cpp"
  submodule_state "$SRC/llama.cpp"
  toolchain
  local slice
  for slice in $ALL_SLICES; do
    slice_args "$slice"
    echo "$slice: ${ARGS[*]}"
  done
  (cd "$SHERPA" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256)
}

"$ROOT/Scripts/fetch-sherpa.sh"
[[ -f "$SHERPA/libsherpa-onnx.a" ]] || fail "missing $SHERPA/libsherpa-onnx.a"

log "hashing inputs"
INPUTS="$(stamp_inputs | shasum -a 256 | cut -d' ' -f1)"

BUILT=""
if [[ "$FORCE" != 1 && -f "$STAMP" && "$(sed -n 's/^inputs //p' "$STAMP")" == "$INPUTS" ]]; then
  BUILT="$(sed -n 's/^platforms //p' "$STAMP")"
fi

TO_BUILD=""
COVERED=1
for slice in $ALL_SLICES; do
  if contains "$REQUESTED" "$slice"; then
    TO_BUILD="$TO_BUILD $slice"
    contains "$BUILT" "$slice" || COVERED=0
  elif contains "$BUILT" "$slice"; then
    # Slices built earlier from the same inputs stay in the xcframework.
    TO_BUILD="$TO_BUILD $slice"
  fi
done
TO_BUILD="${TO_BUILD# }"

if [[ "$COVERED" == 1 && -d "$OUT/OSWNative.xcframework" && -d "$OUT/SherpaOnnx.xcframework" ]]; then
  log "up to date ($BUILT), nothing to do (FORCE=1 rebuilds)"
  exit 0
fi

if [[ "$FORCE" == 1 ]]; then
  log "FORCE=1: clean rebuild of: $TO_BUILD"
elif [[ -f "$STAMP" ]]; then
  log "inputs or requested slices changed, building: $TO_BUILD"
else
  log "no stamp, building: $TO_BUILD"
fi
rm -f "$STAMP"
mkdir -p "$WORK" "$OUT"

# Configures and builds one slice; leaves the merged archive at $WORK/<slice>/libOSWNative.a.
# The configure directory is reused (incremental build) unless the arguments or toolchain changed.
build_slice() {
  local slice="$1" dir="$WORK/$1" logfile="$WORK/$1.log" key started=$SECONDS
  slice_args "$slice"
  key="$(printf '%s\n' "${ARGS[@]}"; toolchain)"
  if [[ "$FORCE" == 1 || "$(cat "$dir/.configure-key" 2>/dev/null || true)" != "$key" ]]; then
    rm -rf "$dir"
  fi

  log "$slice: configuring (log: ${logfile#"$ROOT"/})"
  if ! cmake -S "$SRC" -B "$dir" "${ARGS[@]}" >"$logfile" 2>&1; then
    tail -40 "$logfile" >&2; fail "$slice: cmake configure failed"
  fi
  printf '%s' "$key" >"$dir/.configure-key"

  log "$slice: building whisper and llama (Release)"
  if ! cmake --build "$dir" --config Release --target whisper llama >>"$logfile" 2>&1; then
    grep -E 'error:|BUILD FAILED' "$logfile" | head -40 >&2 || tail -40 "$logfile" >&2
    fail "$slice: cmake build failed"
  fi

  local found expected name libs=()
  found="$(find "$dir" -path '*/Release*/lib*.a' -not -path '*/Objects-normal/*' -type f | sed 's|.*/lib\(.*\)\.a$|\1|' | sort | tr '\n' ' ')"
  expected="$(echo $ARCHIVES | tr ' ' '\n' | sort | tr '\n' ' ')"
  [[ "$found" == "$expected" ]] || fail "$slice: archives are [$found], expected [$expected]"
  for name in $ARCHIVES; do
    libs+=("$(find "$dir" -path "*/Release*/lib$name.a" -not -path '*/Objects-normal/*' -type f)")
  done
  libtool -static -no_warning_for_no_symbols -o "$dir/libOSWNative.a" "${libs[@]}"
  log "$slice: built and merged ${#libs[@]} archives in $((SECONDS - started))s"
}

verify_slice() {
  local slice="$1" lib="$2" archs arch versions symbols
  slice_expect "$slice"
  archs="$(lipo -archs "$lib" | tr ' ' '\n' | sort | tr '\n' ' ')"
  [[ "$archs" == "$EXPECT_ARCHS " ]] || fail "$slice: architectures [$archs], expected [$EXPECT_ARCHS]"
  for arch in $EXPECT_ARCHS; do
    versions="$(otool -arch "$arch" -l "$lib" \
      | awk '/cmd LC_BUILD_VERSION/ {b=1} b && $1=="platform" {p=$2} b && $1=="minos" {print p, $2; b=0}' \
      | sort -u | tr '\n' ' ')"
    [[ "$versions" == "$EXPECT_PLATFORM $EXPECT_MINOS " ]] \
      || fail "$slice/$arch: build versions [$versions], expected [$EXPECT_PLATFORM $EXPECT_MINOS]"
    symbols="$(nm -m -arch "$arch" "$lib" 2>/dev/null)"
    grep -q '(__DATA,__ggml_metallib) external _ggml_metallib_start$' <<<"$symbols" \
      || fail "$slice/$arch: embedded Metal library (_ggml_metallib_start) missing"
    grep -q ') private external _whisper_full$' <<<"$symbols" || fail "$slice/$arch: _whisper_full missing"
    grep -q ') private external _llama_backend_init$' <<<"$symbols" || fail "$slice/$arch: _llama_backend_init missing"
    if grep -qE ' (___kmpc_|_omp_)' <<<"$symbols"; then fail "$slice/$arch: OpenMP symbols present"; fi
    if [[ "$slice" == ios ]]; then
      otool -arch "$arch" -tv "$lib" >"$WORK/$slice.s"
      grep -E "$BEYOND_ARMV8_0" "$WORK/$slice.s" | grep -vE "$ARMV8_0_HALF" >"$WORK/$slice.beyond-armv8" || true
      if [[ -s "$WORK/$slice.beyond-armv8" ]]; then
        head -5 "$WORK/$slice.beyond-armv8" >&2
        fail "$slice/$arch: instructions that some iOS 17 devices lack (all: build-native/$slice.beyond-armv8)"
      fi
    fi
    log "$slice/$arch: ok (platform $EXPECT_PLATFORM, minos $EXPECT_MINOS, Metal library embedded, no OpenMP)"
  done
}

stage_headers() {
  local dest="$WORK/headers/OSWNative" header name inc
  rm -rf "$WORK/headers"
  mkdir -p "$dest"
  for header in $HEADERS; do
    cp "$SRC/$header" "$dest/"
  done
  for header in "$dest"/*.h; do
    for inc in $(sed -n 's/^#include "\(.*\)"/\1/p' "$header"); do
      [[ -f "$dest/$inc" ]] || fail "$(basename "$header") includes $inc, which is not staged"
    done
  done
  {
    echo "module OSWNative {"
    for header in $HEADERS; do
      echo "    header \"$(basename "$header")\""
    done
    echo "    export *"
    echo "    link \"c++\""
    echo "    link framework \"Accelerate\""
    echo "    link framework \"Metal\""
    echo "    link framework \"Foundation\""
    echo "}"
  } >"$dest/module.modulemap"
}

package_sherpa() {
  local headers="$WORK/sherpa-headers"
  rm -rf "$headers" "$WORK/SherpaOnnx.xcframework"
  mkdir -p "$headers/sherpa_onnx"
  cp -R "$SHERPA/Headers/sherpa-onnx" "$headers/"
  cat >"$headers/sherpa_onnx/module.modulemap" <<'EOF'
module sherpa_onnx {
    header "../sherpa-onnx/c-api/c-api.h"
    link "c++"
    export *
}
EOF
  xcodebuild -create-xcframework -library "$SHERPA/libsherpa-onnx.a" -headers "$headers" \
    -output "$WORK/SherpaOnnx.xcframework" >/dev/null
}

xcf_args=()
for slice in $TO_BUILD; do
  build_slice "$slice"
  verify_slice "$slice" "$WORK/$slice/libOSWNative.a"
  xcf_args+=(-library "$WORK/$slice/libOSWNative.a" -headers "$WORK/headers")
done

log "assembling OSWNative.xcframework ($TO_BUILD)"
stage_headers
rm -rf "$WORK/OSWNative.xcframework"
xcodebuild -create-xcframework "${xcf_args[@]}" -output "$WORK/OSWNative.xcframework" >/dev/null

log "repackaging SherpaOnnx.xcframework (macOS)"
package_sherpa

rm -rf "$OUT/OSWNative.xcframework" "$OUT/SherpaOnnx.xcframework"
mv "$WORK/OSWNative.xcframework" "$WORK/SherpaOnnx.xcframework" "$OUT/"
printf 'inputs %s\nplatforms %s\n' "$INPUTS" "$TO_BUILD" >"$STAMP"
log "done: ${OUT#"$ROOT"/}/{OSWNative,SherpaOnnx}.xcframework ($TO_BUILD)"
