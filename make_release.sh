#!/bin/bash
set -e

# Configuration
NEW_VERSION="${1:-0.0.4}"
APP_NAME="OpenSuperWhisper"
# Which slice notarize_app.sh built; it names the DMG after it.
ARCH="${ARCH:-arm64}"
# Releases go to this fork, not to the upstream project we forked from.
REPO="${REPO:-my-monkeys/OpenSuperWhisper}"
# Every existing tag is v-prefixed; Sparkle's appcast links to that form.
TAG="v${NEW_VERSION}"
CODE_SIGN_IDENTITY="${2}"
GITHUB_TOKEN="${3}"

if [[ -z "$CODE_SIGN_IDENTITY" ]]; then
    echo "❌ Error: Code signing identity is required"
    echo "Usage: $0 <version> <code_sign_identity> [github_token]"
    echo "Example: $0 0.0.4 \"Developer ID Application: Your Name (TEAM_ID)\" ghp_xxxxx"
    exit 1
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
    echo ""
    echo "⚠️  GitHub token not found in environment or arguments"
    echo ""
    read -p "Enter GitHub token (or press Enter to skip GitHub release): " INPUT_TOKEN
    if [[ -n "$INPUT_TOKEN" ]]; then
        GITHUB_TOKEN="$INPUT_TOKEN"
        echo "✅ GitHub token provided"
    else
        echo ""
        echo "⚠️  WARNING: Proceeding without GitHub token"
        echo "   - Git tag will be created and pushed"
        echo "   - GitHub release will NOT be created automatically"
        echo "   - DMG will NOT be uploaded to GitHub"
        echo ""
        read -p "Continue without GitHub release? (y/N): " CONTINUE
        if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
            echo "❌ Aborted by user"
            exit 1
        fi
    fi
else
    echo "✅ Using GitHub token from environment variable"
fi

# Checked before anything is built, because the failure it catches surfaces at the very end.
# Notarisation is the last step and takes tens of minutes to reach; on 0.12.4 the credentials
# turned out to be unreadable and the whole build was wasted discovering it. Two seconds here
# buys that back.
echo "🔑 Checking notarisation credentials..."
if ! ( NOTARY_ENV="${NOTARY_ENV:-$HOME/.osw-notary.env}"; [ -f "${NOTARY_ENV}" ] && . "${NOTARY_ENV}"
       xcrun notarytool history --keychain-profile "osw-notary" >/dev/null 2>&1 \
       || { [ -n "${NOTARY_KEY:-}" ] && [ -f "${NOTARY_KEY}" ] \
            && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; } ); then
    echo "❌ notarytool cannot authenticate, so this release would fail after the build."
    echo "   Register the profile from a Terminal window:"
    echo "     xcrun notarytool store-credentials \"osw-notary\" --key <p8> --key-id <id> --issuer <issuer>"
    echo "   or write NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER into ~/.osw-notary.env"
    echo ""
    echo "   Note: the keychain profile lives in the data-protection keychain and can only be"
    echo "   read by a process able to show an authorisation prompt, so a release driven from a"
    echo "   non-interactive shell needs the ~/.osw-notary.env route."
    exit 1
fi
echo "✅ Notarisation credentials usable"

echo ""
echo "🚀 Making release for OpenSuperWhisper v${NEW_VERSION}"
echo "   Code signing identity: ${CODE_SIGN_IDENTITY}"
if [[ -n "$GITHUB_TOKEN" ]]; then
    echo "   GitHub release: ✅ Enabled"
else
    echo "   GitHub release: ❌ Disabled (no token)"
fi
echo ""

# # Update version in Xcode project
echo "📝 Updating version to ${NEW_VERSION} in Xcode project..."

# A release is two runs of this script, one per architecture, and the second must not look
# like a different version of the app. Sparkle compares build numbers, not marketing versions,
# so two slices of one release carrying different builds is an app that offers to update itself
# to itself, with the Intel machine and the Apple Silicon one disagreeing about which is newer.
# Bumping unconditionally, which is what this did, guaranteed exactly that; it was worked around
# by hand on 0.12.0, 0.12.1 and 0.12.2.
PROJECT_FILE="OpenSuperWhisper.xcodeproj/project.pbxproj"
PREVIOUS_VERSION=$(grep -o 'MARKETING_VERSION = [^;]*' "${PROJECT_FILE}" | head -1 | sed 's/.*= *//')
CURRENT_PROJECT_VERSION=$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' "${PROJECT_FILE}" | head -1 | grep -o '[0-9]*')

if [[ "${PREVIOUS_VERSION}" == "${NEW_VERSION}" ]]; then
    NEW_PROJECT_VERSION="${CURRENT_PROJECT_VERSION}"
    SECOND_ARCH=true
    echo "📝 ${NEW_VERSION} is already prepared at build ${NEW_PROJECT_VERSION}."
    echo "   Treating this as the ${ARCH} slice of a release already under way."
else
    NEW_PROJECT_VERSION=$((CURRENT_PROJECT_VERSION + 1))
    SECOND_ARCH=false
    sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = ${NEW_VERSION}/g" "${PROJECT_FILE}"
    sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = ${NEW_PROJECT_VERSION}/g" "${PROJECT_FILE}"
    echo "✅ ${PREVIOUS_VERSION} -> ${NEW_VERSION}, build ${CURRENT_PROJECT_VERSION} -> ${NEW_PROJECT_VERSION}"
fi

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf build
rm -f OpenSuperWhisper-*.dmg
rm -f OpenSuperWhisper-*.dmg.sha256
rm -f OpenSuperWhisper*.app.dSYM.zip

# Use the existing notarize_app.sh script to build, sign, and notarize
echo "🔨 Building, signing and notarizing with notarize_app.sh..."
if [[ ! -f "./notarize_app.sh" ]]; then
    echo "❌ notarize_app.sh not found!"
    exit 1
fi

chmod +x ./notarize_app.sh
# No exit-code check here: `set -e` already aborts on a non-zero return, so a test on $? would
# only ever see the 0 of a script that succeeded.
# ARCH has to be passed positionally. `notarize_app.sh` reads it as `${2:-arm64}`, so leaving it
# off does not inherit it from the environment, it silently builds arm64 — and then also skips
# the two things that run only for x86_64 in there: stripping the arm64-only onnxruntime, and
# pointing Sparkle at the x86_64 appcast. An Intel release built this way is an ARM binary under
# an Intel name, subscribed to the wrong update feed. The DMG filename carries the architecture,
# so the run dies looking for a file that was never made, which is the only reason this was a
# failed release rather than a wrong one.
./notarize_app.sh "${CODE_SIGN_IDENTITY}" "${ARCH}"

echo "✅ Build and notarization successful!"

DMG_PATH="./${APP_NAME}-${ARCH}.dmg"

# Verify DMG exists
if [[ ! -f "$DMG_PATH" ]]; then
    echo "❌ DMG not found at $DMG_PATH"
    exit 1
fi

# Find and prepare dSYM
DSYM_PATH="./build/Build/Products/Release/OpenSuperWhisper.app.dSYM"
# Named per architecture: the two slices have different symbols, and uploading both under one
# name left whichever lost the race with none to read a crash report against.
#
# Absolute, because the zip is made from inside the build directory. Relative, the `mv` that
# was meant to bring it back to the repo root renamed it onto itself and left it in the build
# directory, so the `-f` test below found nothing and the upload was skipped without a word.
# No release has ever carried a dSYM: not 0.12.2, not 0.12.1, not 0.12.0. Which means every
# crash report we have been sent had no symbols to read it against.
DSYM_ZIP_PATH="$(pwd)/OpenSuperWhisper-${ARCH}-${NEW_VERSION}.app.dSYM.zip"

if [[ -d "$DSYM_PATH" ]]; then
    echo "📦 Creating dSYM zip..."
    rm -f "$DSYM_ZIP_PATH"
    # A subshell, so a failure here cannot leave the rest of the script in the build directory.
    (cd "$(dirname "$DSYM_PATH")" && zip -r -q "$DSYM_ZIP_PATH" "$(basename "$DSYM_PATH")")
    if [[ ! -f "$DSYM_ZIP_PATH" ]]; then
        echo "❌ dSYM zip was not written to $DSYM_ZIP_PATH"
        exit 1
    fi
    echo "✅ dSYM zip created: $DSYM_ZIP_PATH ($(du -h "$DSYM_ZIP_PATH" | cut -f1))"
else
    echo "⚠️ dSYM not found at $DSYM_PATH - skipping dSYM upload"
    DSYM_ZIP_PATH=""
fi

# # Generate SHA256
echo "🔍 Generating SHA256..."
shasum -a 256 "$DMG_PATH" > "${DMG_PATH}.sha256"
SHA256=$(cat "${DMG_PATH}.sha256" | cut -d' ' -f1)
echo "SHA256: $SHA256"

# Commit, tag and push, unless the second architecture is retracing steps the first already
# took. Re-tagging fails, and `set -e` would abort the run after a forty-minute notarisation.
if [[ "${SECOND_ARCH}" == "true" ]]; then
    echo "🏷️ Tag ${TAG} exists; this run only adds the ${ARCH} build to it."
else
    echo "📝 Committing version changes..."
    git add "${PROJECT_FILE}"
    git commit -m "Bump version to ${NEW_VERSION}" || echo "No changes to commit"

    echo "🏷️ Creating git tag..."
    git tag -a "${TAG}" -m "Release ${NEW_VERSION}"

    echo "📤 Pushing tag to origin..."
    git push origin "${TAG}"
fi

# Create GitHub release and upload DMG if token is provided
if [[ -n "$GITHUB_TOKEN" ]]; then
    # The second architecture joins the release the first one made. A tag carries one release,
    # so creating it again just fails.
    # `|| true` is load-bearing. On the FIRST architecture there is no release yet, the lookup
    # 404s, `grep` matches nothing and exits 1, and under `set -e` an assignment from a failing
    # command substitution aborts the script — right after the tag has been pushed and forty
    # minutes of notarisation have completed. Finding nothing here is the normal case, not an
    # error.
    RELEASE_ID=$(curl -s -L \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" \
        | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*' || true)

    if [[ -n "$RELEASE_ID" ]]; then
        echo "🚀 Release ${TAG} exists (ID: $RELEASE_ID), adding the ${ARCH} build."
    else
        echo "🚀 Creating GitHub release..."
    
        # Create release
        RELEASE_RESPONSE=$(curl -s -L -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            https://api.github.com/repos/${REPO}/releases \
            -d '{
                "tag_name": "'${TAG}'",
                "target_commitish": "master",
                "name": "Release '${NEW_VERSION}'",
                "body": "## OpenSuperWhisper '${NEW_VERSION}'\n\nReal-time audio transcription for macOS using Whisper.\n\n## Installation\n\n### Homebrew (Recommended)\n```bash\nbrew install --cask my-monkeys/tap/opensuperwhisper\n```\nUse the full `my-monkeys/tap/` path: the bare name resolves to the original unmaintained cask, not this fork.\n\n### Manual Installation\n1. Download the `'${APP_NAME}-${ARCH}-${NEW_VERSION}'.dmg` file below\n2. Open the DMG and drag OpenSuperWhisper to Applications\n3. Launch the app and grant necessary permissions\n\n## Requirements\n- macOS 14.0 (Sonoma) or later\n- Apple Silicon or Intel",
                "draft": false,
                "prerelease": false,
                "generate_release_notes": false
            }')
    
        # Extract release ID from response
        # Same reason: a creation that failed has no id to find, and the explicit check just
        # below is what should report that, with the response body, rather than `set -e`
        # killing the run one line earlier and saying nothing.
        RELEASE_ID=$(echo "$RELEASE_RESPONSE" | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*' || true)
    
        if [[ -z "$RELEASE_ID" ]]; then
            echo "❌ Failed to create GitHub release or extract release ID"
            echo "Response: $RELEASE_RESPONSE"
            exit 1
        fi
    
        echo "✅ GitHub release created (ID: $RELEASE_ID)!"
    fi

    echo "📤 Uploading DMG..."
    
    # Upload DMG using the correct API format
    UPLOAD_RESPONSE=$(curl -s -L -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/octet-stream" \
        "https://uploads.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets?name=${APP_NAME}-${ARCH}-${NEW_VERSION}.dmg" \
        --data-binary @"${DMG_PATH}")
    
    # Check if upload was successful
    if [[ $(echo "$UPLOAD_RESPONSE" | grep -c '"state":"uploaded"') -gt 0 ]] || [[ $(echo "$UPLOAD_RESPONSE" | grep -c '"state": "uploaded"') -gt 0 ]]; then
        echo "✅ DMG uploaded successfully!"
        # Extract download URL
        DOWNLOAD_URL=$(echo "$UPLOAD_RESPONSE" | grep -o '"browser_download_url":"[^"]*' | cut -d'"' -f4)
        echo "📥 Download URL: $DOWNLOAD_URL"
    elif [[ $(echo "$UPLOAD_RESPONSE" | grep -c '"message"') -gt 0 ]]; then
        echo "❌ Failed to upload DMG"
        echo "Error: $(echo "$UPLOAD_RESPONSE" | grep -o '"message":"[^"]*' | cut -d'"' -f4)"
        exit 1
    else
        echo "⚠️ Upload response unclear, but no error detected"
        echo "Response: $UPLOAD_RESPONSE"
    fi
    
    # Upload dSYM if available
    if [[ -n "$DSYM_ZIP_PATH" && -f "$DSYM_ZIP_PATH" ]]; then
        echo "📤 Uploading dSYM..."
        
        DSYM_UPLOAD_RESPONSE=$(curl -s -L -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Content-Type: application/zip" \
            "https://uploads.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets?name=$(basename "${DSYM_ZIP_PATH}")" \
            --data-binary @"${DSYM_ZIP_PATH}")
        
        # Check dSYM upload
        if [[ $(echo "$DSYM_UPLOAD_RESPONSE" | grep -c '"state":"uploaded"') -gt 0 ]] || [[ $(echo "$DSYM_UPLOAD_RESPONSE" | grep -c '"state": "uploaded"') -gt 0 ]]; then
            echo "✅ dSYM uploaded successfully!"
            # Extract download URL
            DSYM_DOWNLOAD_URL=$(echo "$DSYM_UPLOAD_RESPONSE" | grep -o '"browser_download_url":"[^"]*' | cut -d'"' -f4)
            echo "📥 dSYM Download URL: $DSYM_DOWNLOAD_URL"
        elif [[ $(echo "$DSYM_UPLOAD_RESPONSE" | grep -c '"message"') -gt 0 ]]; then
            echo "⚠️ Failed to upload dSYM (non-critical)"
            echo "Error: $(echo "$DSYM_UPLOAD_RESPONSE" | grep -o '"message":"[^"]*' | cut -d'"' -f4)"
        else
            echo "⚠️ dSYM upload response unclear"
        fi
    fi
    
    echo "✅ DMG uploaded successfully!"
    echo "🎉 GitHub release is complete!"
    echo "🔗 Release URL: https://github.com/${REPO}/releases/tag/${TAG}"
else
    echo "⚠️ Skipping GitHub release creation (no token provided)"
    echo "📋 Manual steps needed:"
    echo "1. Create GitHub release at:"
    echo "   https://github.com/${REPO}/releases/new?tag=${TAG}"
    echo "2. Upload the DMG file: ${DMG_PATH}"
fi

echo ""
echo "🎉 Release ${NEW_VERSION} is ready!"
echo ""
echo "📁 Files created:"
echo "   - ${DMG_PATH}"
echo "   - ${DMG_PATH}.sha256"
if [[ -f "$DSYM_ZIP_PATH" ]]; then
    echo "   - $(basename "${DSYM_ZIP_PATH}")"
fi
echo ""
echo "🍺 Homebrew tap:"
# Not printed for someone to copy by hand any more. What used to be printed here was a
# single-arch cask that declared `depends_on arch: :arm64` and zapped `ru.starmel.*`, the bundle
# ID of the project this was forked from — following it produced a cask that was wrong for Intel
# and cleaned up nothing. So nobody followed it, and the tap sat on 0.9.9 for three releases
# while Homebrew was the first install route in our own README (#106).
#
# The bump reads the checksums off the published release rather than off this build, so it can
# only run once BOTH architectures are uploaded. Releasing the second one is what completes it;
# on the first it says so and stops, which is a state to expect rather than a failure.
if [[ -x "./update_homebrew_tap.sh" ]]; then
    ./update_homebrew_tap.sh "${NEW_VERSION}" || {
        echo ""
        echo "⚠️  The tap was not updated. Run this once the other architecture is published:"
        echo "    ./update_homebrew_tap.sh ${NEW_VERSION}"
    }
else
    echo "⚠️  update_homebrew_tap.sh not found; the tap still points at whatever it did before."
fi
