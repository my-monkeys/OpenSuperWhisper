#!/bin/bash
# pipefail is what makes a failed build fail the script: xcodebuild is piped into xcpretty,
# and a pipeline reports the status of its last command, so xcpretty's cheerful 0 was hiding
# "** BUILD FAILED **" and letting the release carry on with a stale app bundle.
set -e -o pipefail

# === Configuration ===
# Usage: ./notarize_app.sh "Developer ID Application: … (TEAMID)" [arm64|x86_64]
#   arm64  (default) — Apple Silicon, all three engines (Whisper, Parakeet, SenseVoice)
#   x86_64           — Intel; SenseVoice is dropped (onnxruntime ships arm64-only), and the
#                      build points Sparkle at its own appcast (appcast-x86_64.xml).
APP_NAME="OpenSuperWhisper"
APP_PATH="./build/Build/Products/Release/OpenSuperWhisper.app"
ZIP_PATH="./build/OpenSuperWhisper.zip"
BUNDLE_ID="fr.my-monkey.opensuperwhisper"
KEYCHAIN_PROFILE="osw-notary"

# How notarytool is authenticated, worked out once and reused for both submissions.
#
# The keychain profile is the normal path, but it lives in the data-protection keychain, and an
# item there can only be read by a process able to put an authorisation prompt on screen. A
# release driven from a non-interactive shell therefore gets `errSecInteractionNotAllowed` and
# reports it as "No Keychain password item found", which reads like the profile is missing rather
# than unreadable. That cost a full build on 0.12.4: ten minutes of compiling before the failure
# surfaced.
#
# So the App Store Connect key is accepted directly as a fallback. Put the three values in
# ~/.osw-notary.env, outside the repo:
#
#   NOTARY_KEY=$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
#   NOTARY_KEY_ID=XXXXXXXXXX
#   NOTARY_ISSUER=00000000-0000-0000-0000-000000000000
#
# The .p8 is the secret and stays a file with its own permissions; the two identifiers are not
# secret but live there anyway so nothing about the account is committed to a public repo.
NOTARY_ENV="${NOTARY_ENV:-$HOME/.osw-notary.env}"
[ -f "${NOTARY_ENV}" ] && . "${NOTARY_ENV}"

notary_auth_args() {
    if xcrun notarytool history --keychain-profile "${KEYCHAIN_PROFILE}" >/dev/null 2>&1; then
        printf '%s' "--keychain-profile ${KEYCHAIN_PROFILE}"
        return 0
    fi
    if [ -n "${NOTARY_KEY:-}" ] && [ -f "${NOTARY_KEY}" ] \
       && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
        printf '%s' "--key ${NOTARY_KEY} --key-id ${NOTARY_KEY_ID} --issuer ${NOTARY_ISSUER}"
        return 0
    fi
    return 1
}

if ! NOTARY_AUTH=$(notary_auth_args); then
    echo "❌ notarytool has no usable credentials."
    echo "   The keychain profile \"${KEYCHAIN_PROFILE}\" is missing or cannot be read from a"
    echo "   non-interactive shell. Either register it from a Terminal window:"
    echo "     xcrun notarytool store-credentials \"${KEYCHAIN_PROFILE}\" --key <p8> --key-id <id> --issuer <issuer>"
    echo "   or write the same three values into ${NOTARY_ENV} (see the comment in this script)."
    exit 1
fi
CODE_SIGN_IDENTITY="${1}"
ARCH="${2:-arm64}"
DEVELOPMENT_TEAM="5C67TFSJ2B"
DMG_NAME="${APP_NAME}-${ARCH}"

if [ "${ARCH}" != "arm64" ] && [ "${ARCH}" != "x86_64" ]; then
  echo "ARCH must be arm64 or x86_64 (got '${ARCH}')"; exit 1
fi

# Releases MUST be built with a STABLE Xcode. Xcode 27 beta (Swift 6.4) miscompiles
# MainActor isolation across an await (swiftlang/swift#89214) — 0.9.5 shipped from it
# and crashed on every button tap for macOS 26/27 users. Refuse a beta toolchain.
# Drive the toolchain with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
XCODE_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}"
if [[ "${XCODE_DIR}" == *[Bb]eta* && "${ALLOW_BETA_XCODE:-0}" != "1" ]]; then
  echo "❌ Refusing to build a release with a BETA Xcode:"
  echo "     ${XCODE_DIR}"
  echo "   Xcode 27 beta / Swift 6.4 miscompiles MainActor isolation → runtime crashes (#89214)."
  echo "   Build with the stable Xcode instead:"
  echo "     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0 \"\$IDENTITY\" ${ARCH}"
  echo "   (Only override if you've confirmed the toolchain is fixed:  ALLOW_BETA_XCODE=1 …)"
  exit 1
fi

echo "=== Building ${APP_NAME} for ${ARCH} (toolchain: ${XCODE_DIR}) ==="

./Scripts/fetch-sherpa.sh
./Scripts/fetch-libomp-universal.sh

# libwhisper: generic CPU flags (no -mcpu=native) + both arches so either slice can be linked.
rm -rf libwhisper/build
cmake -G Xcode -B libwhisper/build -S libwhisper -DGGML_NATIVE=OFF -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"

rm -rf build
mkdir -p build

# autocorrect: universal, pinned to deployment target 14.0 (the SDK default is far higher).
#
# The macOS 26/27 beta toolchain links the Rust dylib with a mis-aligned LINKEDIT string pool
# that ld then rejects for the arm64 slice ("mis-aligned LINKEDIT string pool"), breaking the
# universal build. Until that's fixed upstream, reuse a known-good prebuilt universal dylib when
# one is vendored (the autocorrect source rarely changes); otherwise build from source.
if [ -f vendor/libautocorrect_swift.dylib ]; then
  echo "Using vendored prebuilt autocorrect-swift (beta-toolchain workaround)..."
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
codesign --force --sign "${CODE_SIGN_IDENTITY}" --timestamp ./build/libautocorrect_swift.dylib

echo "Copying libomp.dylib (universal)..."
cp vendor/libomp-universal.dylib ./build/libomp.dylib
install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib
codesign --force --sign "${CODE_SIGN_IDENTITY}" --timestamp ./build/libomp.dylib

# onnxruntime is arm64-only and only the arm64 build links it (OTHER_LDFLAGS[arch=arm64]); the
# x86_64 build still needs the file present for the embed phase, then strips it post-build.
echo "Copying libonnxruntime.dylib..."
cp vendor/onnxruntime/libonnxruntime.1.24.4.dylib ./build/libonnxruntime.1.24.4.dylib
ln -sf libonnxruntime.1.24.4.dylib ./build/libonnxruntime.dylib
codesign --force --sign "${CODE_SIGN_IDENTITY}" --timestamp ./build/libonnxruntime.1.24.4.dylib

xcodebuild \
  -scheme "OpenSuperWhisper" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  ARCHS="${ARCH}" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -derivedDataPath build \
  build | xcpretty --simple --color

# Intel build: drop the arm64-only onnxruntime (unused, SenseVoice is compiled out) and point
# Sparkle at the x86_64 feed so the two arch variants never offer each other's downloads.
if [ "${ARCH}" = "x86_64" ]; then
  echo "x86_64: stripping arm64 onnxruntime + setting x86_64 appcast feed..."
  rm -f "${APP_PATH}/Contents/Frameworks/libonnxruntime"*.dylib
  /usr/libexec/PlistBuddy -c \
    "Set :SUFeedURL https://raw.githubusercontent.com/my-monkeys/OpenSuperWhisper/master/appcast-x86_64.xml" \
    "${APP_PATH}/Contents/Info.plist"
fi

# Sparkle embeds nested helpers (Updater.app, Autoupdate, XPC services) that each need a
# Developer-ID signature with hardened runtime + secure timestamp; then the outer app must be
# re-signed (re-signing nested code — and our post-build edits — invalidates the bundle seal).
SPARKLE_FW="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
if [ -d "${SPARKLE_FW}" ]; then
  echo "Re-signing Sparkle helpers..."
  SPK="${SPARKLE_FW}/Versions/Current"
  for comp in \
    "${SPK}/XPCServices/Downloader.xpc" \
    "${SPK}/XPCServices/Installer.xpc" \
    "${SPK}/Autoupdate" \
    "${SPK}/Updater.app"; do
    [ -e "${comp}" ] && codesign -f -o runtime --timestamp -s "${CODE_SIGN_IDENTITY}" "${comp}"
  done
  codesign -f -o runtime --timestamp -s "${CODE_SIGN_IDENTITY}" "${SPARKLE_FW}"
fi
# Always re-seal the app (covers the Sparkle re-sign and the x86_64 post-build edits).
codesign -f -o runtime --timestamp \
  --entitlements "OpenSuperWhisper/OpenSuperWhisper.entitlements" \
  -s "${CODE_SIGN_IDENTITY}" "${APP_PATH}"
codesign --verify --strict --verbose=1 "${APP_PATH}"

rm -f "${ZIP_PATH}"
current_dir=$(pwd)
cd $(dirname "${APP_PATH}") && zip -r -y "${current_dir}/${ZIP_PATH}" $(basename "${APP_PATH}")
cd "${current_dir}"

xcrun notarytool submit "${ZIP_PATH}" --wait ${NOTARY_AUTH}
xcrun stapler staple "${APP_PATH}"

# Build the DMG with hdiutil (no extra tooling): the .app + an Applications symlink.
DMG_STAGE="$(mktemp -d)"
cp -R "${APP_PATH}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"
rm -f "${DMG_NAME}.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGE}" -ov -format UDZO "${DMG_NAME}.dmg"
rm -rf "${DMG_STAGE}"

codesign --sign "${CODE_SIGN_IDENTITY}" "${DMG_NAME}.dmg"
xcrun notarytool submit "${DMG_NAME}.dmg" --wait ${NOTARY_AUTH}
xcrun stapler staple "${DMG_NAME}.dmg"

echo "Successfully notarized ${APP_NAME} (${ARCH}) → ${DMG_NAME}.dmg"
