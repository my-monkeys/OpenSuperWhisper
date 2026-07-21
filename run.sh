#!/bin/zsh

JUST_BUILD=false
BUILD_IOS=false
if [[ "$1" == "build" ]]; then
    JUST_BUILD=true
elif [[ "$1" == "build-ios" ]]; then
    BUILD_IOS=true
elif [[ -n "$1" ]]; then
    echo "usage: $0 [build|build-ios]"
    exit 1
fi

# Patch FluidAudio's vocabulary rescorer to prefer longer matching spans
# (keyword boosting quality, e.g. "My-Monkey" matched as one term). Idempotent;
# fails loudly if the target moved (so a FluidAudio bump can't silently skip it).
apply_fluidaudio_patches() {
    local checkout="SourcePackages/checkouts/FluidAudio"
    local patch_file="patches/fluidaudio-vocabulary-rescorer.patch"
    local target="$checkout/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/CustomVocabulary/Rescorer/VocabularyRescorer+TokenRescoring.swift"

    if [[ ! -f "$patch_file" ]]; then
        echo "Missing FluidAudio patch: $patch_file"
        exit 1
    fi

    if [[ ! -f "$target" ]]; then
        echo "Missing FluidAudio source checkout: $target"
        exit 1
    fi

    if grep -q "Prefer longer spans" "$target"; then
        echo "FluidAudio vocabulary rescorer patch already applied."
        return
    fi

    echo "Applying FluidAudio vocabulary rescorer patch..."
    patch --silent --forward -d "$checkout" -p1 < "$patch_file"
    if [[ $? -ne 0 ]] && ! grep -q "Prefer longer spans" "$target"; then
        echo "Failed to apply FluidAudio vocabulary rescorer patch."
        exit 1
    fi
}

# iOS lane: ./run.sh build-ios — SPM resolve + FluidAudio patch (SHARED with the
# macOS flow per plan G1: both platforms consume the same patched SourcePackages
# checkout), then the whisper iOS xcframework. The macOS-only steps below (cmake
# libwhisper, sherpa, cargo, dylib staging, dev-codesign) never run on this lane.
# The package-resolve invocation is duplicated from the macOS flow on purpose:
# keeping it inline leaves everything below this branch byte-identical to the
# pre-iOS script. The iOS app target lands in commit 3 — until then the lane
# stops after the xcframework.
if $BUILD_IOS; then
    echo "Resolving Swift packages..."
    RESOLVE_OUTPUT=$(xcodebuild -resolvePackageDependencies -scheme OpenSuperWhisper -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages -skipPackagePluginValidation -skipMacroValidation 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "$RESOLVE_OUTPUT"
        echo "Swift package resolution failed!"
        exit 1
    fi

    apply_fluidaudio_patches

    ./Scripts/build-xcframework-ios.sh

    # Commit 3: the iOS host app target exists — build it (Simulator, unsigned).
    # Same -derivedDataPath/-clonedSourcePackagesDirPath as the rest of the lane:
    # a divergent path re-resolves FluidAudio UNPATCHED (banked repo invariant).
    echo "Building OpenSuperWhisper-iOS (iOS Simulator, unsigned)..."
    IOS_BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperWhisper-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO build 2>&1)
    IOS_BUILD_EXIT=$?

    if command -v xcpretty &> /dev/null
    then
        echo "$IOS_BUILD_OUTPUT" | xcpretty --simple --color
    else
        echo "$IOS_BUILD_OUTPUT"
    fi

    # Check the captured xcodebuild exit (captured above — pipeline exits would
    # clobber $?) and the log text for a failed build.
    if [[ $IOS_BUILD_EXIT -ne 0 ]] || [[ "$IOS_BUILD_OUTPUT" =~ "BUILD FAILED" ]]; then
        echo "iOS app build failed!"
        exit 1
    fi

    echo "build-ios complete: build/whisper-ios.xcframework + OpenSuperWhisper-iOS (Simulator build green)."
    exit 0
fi

# Configure libwhisper
echo "Configuring libwhisper..."
cmake -G Xcode -B libwhisper/build -S libwhisper
if [[ $? -ne 0 ]]; then
    echo "CMake configuration failed!"
    exit 1
fi

./Scripts/fetch-sherpa.sh

echo "Building autocorrect-swift..."
mkdir -p build
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin --manifest-path=asian-autocorrect/Cargo.toml
cp ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
codesign --force --sign - ./build/libautocorrect_swift.dylib
if [[ $? -ne 0 ]]; then
    echo "Cargo build failed!"
    exit 1
fi

echo "Copying libomp.dylib..."
cp /opt/homebrew/opt/libomp/lib/libomp.dylib ./build/libomp.dylib
install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib
codesign --force --sign - ./build/libomp.dylib

echo "Copying libonnxruntime.dylib..."
cp vendor/onnxruntime/libonnxruntime.1.24.4.dylib ./build/libonnxruntime.1.24.4.dylib
ln -sf libonnxruntime.1.24.4.dylib ./build/libonnxruntime.dylib
codesign --force --sign - ./build/libonnxruntime.1.24.4.dylib

# Resolve Swift packages so the FluidAudio checkout exists, then patch it.
echo "Resolving Swift packages..."
RESOLVE_OUTPUT=$(xcodebuild -resolvePackageDependencies -scheme OpenSuperWhisper -derivedDataPath build -clonedSourcePackagesDirPath SourcePackages -skipPackagePluginValidation -skipMacroValidation 2>&1)
if [[ $? -ne 0 ]]; then
    echo "$RESOLVE_OUTPUT"
    echo "Swift package resolution failed!"
    exit 1
fi

apply_fluidaudio_patches

# Build the app
echo "Building OpenSuperWhisper..."
BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperWhisper -configuration Debug -jobs 8 -derivedDataPath build -quiet -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperWhisper/OpenSuperWhisper.entitlements" build 2>&1)
BUILD_EXIT=$?

# sudo gem install xcpretty
if command -v xcpretty &> /dev/null
then
    echo "$BUILD_OUTPUT" | xcpretty --simple --color
else
    echo "$BUILD_OUTPUT"
fi

# Check the captured xcodebuild exit (captured above — pipeline exits would
# clobber $?) and the log text for a failed build.
if [[ $BUILD_EXIT -eq 0 ]] && [[ ! "$BUILD_OUTPUT" =~ "BUILD FAILED" ]]; then
    echo "Building successful!"
    # Re-sign with a stable identity so macOS keeps granted TCC permissions
    # across rebuilds (no-op / ad-hoc fallback when no identity is available).
    "$(dirname "$0")/Scripts/dev-codesign.sh" "./Build/Build/Products/Debug/OpenSuperWhisper.app" || true
    if $JUST_BUILD; then
        exit 0
    fi
    echo "Starting the app..."
    # Remove quarantine attribute if exists
    xattr -d com.apple.quarantine ./Build/Build/Products/Debug/OpenSuperWhisper.app 2>/dev/null || true
    # Run the app and show logs
    ./Build/Build/Products/Debug/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper
else
    echo "Build failed!"
    exit 1
fi 