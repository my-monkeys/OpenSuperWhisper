#!/bin/zsh
#
# Runs the core package's tests (docs/core-extraction.md, slice 5) through the project's
# OpenSuperWhisperCoreTests scheme, so they build against the workspace pins and run.sh's
# patched FluidAudio checkout in SourcePackages/.
#
# Usage: Scripts/test-core.sh macos|ios [extra xcodebuild args]
#   macos  this Mac, arm64
#   ios    an iOS Simulator: OSW_SIM_DESTINATION when set (an xcodebuild -destination value),
#          otherwise the first iPhone of the newest installed iOS runtime that the active
#          Xcode's simulator SDK can target
#
# Run ./run.sh build first: it fetches sherpa and onnxruntime, builds the macOS native slices,
# resolves SourcePackages and patches FluidAudio. The iOS slices are built here when missing.
# Pass -resultBundlePath to keep an .xcresult; an existing one at that path is deleted first,
# because xcodebuild refuses to overwrite it. TEST_RUNNER_* variables reach the tests on both
# destinations (TEST_RUNNER_OSW_TEST_GGUF, TEST_RUNNER_OSW_GOLDEN_MACHINE).
#
# Never `swift test`: it resolves on its own into .build/ with an unpatched FluidAudio and
# writes OpenSuperWhisperCore/Package.resolved.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "test-core: error: $*" >&2; exit 1; }

PLATFORM="${1:-}"
[[ "$PLATFORM" == macos || "$PLATFORM" == ios ]] || { echo "usage: $0 macos|ios [xcodebuild args]" >&2; exit 2; }
shift

FLUIDAUDIO=SourcePackages/checkouts/FluidAudio
[[ -d $FLUIDAUDIO ]] || fail "no $FLUIDAUDIO checkout, run ./run.sh build first"
grep -rqF "Prefer longer spans" $FLUIDAUDIO/Sources \
  || fail "the FluidAudio vocabulary rescorer patch is not applied, run ./run.sh build first"

args=("$@")
for (( i = 1; i <= ${#args}; i++ )); do
  if [[ ${args[i]} == -resultBundlePath ]] && (( i < ${#args} )); then
    rm -rf "${args[i+1]}"
  fi
done

COMMON=(-project OpenSuperWhisper.xcodeproj -scheme OpenSuperWhisperCoreTests
        -derivedDataPath build-core -clonedSourcePackagesDirPath SourcePackages
        -skipPackagePluginValidation -skipMacroValidation -parallel-testing-enabled NO)

# simctl lists every runtime CoreSimulator knows, whichever Xcode is selected; xcodebuild
# refuses a runtime newer than its own SDK (a runner with several Xcodes installed).
newest_iphone() {
  local sdk
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)" || return
  xcrun simctl list devices available -j | jq -r --arg sdk "$sdk" '
    ($sdk | split(".") | map(tonumber)) as $max
    | .devices | to_entries
    | map(select(.key | test("SimRuntime\\.iOS-")))
    | map(.key as $k | {version: ($k | capture("iOS-(?<v>[0-9-]+)$").v | split("-") | map(tonumber)),
                        iphones: (.value | map(select(.name | startswith("iPhone"))))})
    | map(select((.iphones | length > 0) and .version <= $max))
    | sort_by(.version) | last | .iphones[0].udid // empty'
}

rc=0
case "$PLATFORM" in
  macos)
    xcodebuild test "${COMMON[@]}" -destination 'platform=macOS,arch=arm64' \
      "$@" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" || rc=$?
    ;;
  ios)
    [[ -d OpenSuperWhisperCore/Binaries/OSWNative.xcframework/ios-arm64-simulator ]] \
      || Scripts/build-native.sh ios
    DESTINATION="${OSW_SIM_DESTINATION:-}"
    if [[ -z $DESTINATION ]]; then
      udid="$(newest_iphone)"
      [[ -n $udid ]] || fail "no available iPhone simulator the active Xcode supports; set OSW_SIM_DESTINATION"
      xcrun simctl list devices available | grep -F "$udid"
      DESTINATION="platform=iOS Simulator,id=$udid"
    fi
    echo "test-core: destination $DESTINATION"
    # The simulator slice of OSWNative is arm64 only.
    xcodebuild test "${COMMON[@]}" -destination "$DESTINATION" -destination-timeout 180 \
      "$@" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO || rc=$?
    ;;
esac

# The workspace pins are the only resolution file that counts (docs/core-extraction.md, slice 5):
# a run must not leave another one behind, nor move the pins. The root Package.resolved is an old
# tracked file nothing reads; it only has to stay unchanged.
PINS=OpenSuperWhisper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
for file in $(find . -name Package.resolved -not -path './SourcePackages/*' -not -path './build*' -not -path "./$PINS"); do
  git ls-files --error-unmatch "$file" >/dev/null 2>&1 && git diff --quiet -- "$file" && continue
  echo "test-core: error: stray or changed resolution file: $file" >&2; rc=1
done
if git status --porcelain --ignored -- OpenSuperWhisperCore | grep -q Package.resolved; then
  echo "test-core: error: OpenSuperWhisperCore/Package.resolved was written" >&2; rc=1
fi
git diff --exit-code --quiet -- "$PINS" \
  || { echo "test-core: error: the workspace pins changed ($PINS)" >&2; rc=1; }

exit $rc
