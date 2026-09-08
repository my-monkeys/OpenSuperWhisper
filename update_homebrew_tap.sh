#!/bin/bash
#
# Points the Homebrew cask at a published release.
#
# This exists because the tap spent three releases stuck on 0.9.9 (#106). Bumping it was a manual
# step outside the release, so it only happened when somebody noticed, and between July and
# September nobody did. `brew install opensuperwhisper` is the first line of our own install
# instructions, so for two months that line handed people a version from before half the app was
# written.
#
# The checksums are taken from what GitHub actually serves, never from the local build. Those are
# not the same bytes by definition, only by assumption, and the assumption has been wrong here
# before: a stale DMG from the previous version once survived a failed cleanup and was very nearly
# shipped under a new number. Downloading is also the only way to be sure the asset a user will be
# handed exists at all.
#
#   ./update_homebrew_tap.sh 0.12.2
#
# Safe to run twice: it stops without pushing when the cask already says what it would write.

set -e -o pipefail

VERSION="${1}"
REPO="${REPO:-my-monkeys/OpenSuperWhisper}"
TAP="${TAP:-my-monkeys/homebrew-tap}"
CASK_PATH="Casks/opensuperwhisper.rb"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>            e.g. $0 0.12.2"
    exit 1
fi

echo "Pointing the ${TAP} cask at ${REPO} v${VERSION}"

# Both slices, and both are required. A one-armed bump is worse than none: Homebrew picks the
# stanza matching the machine it is running on, so a missing Intel checksum is invisible on the
# Apple Silicon Mac doing the release and breaks every Intel install.
#
# Plain variables rather than an associative array: macOS ships bash 3.2, where `declare -A` is a
# syntax error. Written with one and it failed on the only machine that runs it.
checksum_of() {
    local arch="$1"
    local url="https://github.com/${REPO}/releases/download/v${VERSION}/OpenSuperWhisper-${arch}-${VERSION}.dmg"

    # -f so a 404 is a failure rather than an HTML error page quietly hashed into the cask.
    # `pipefail` is what carries curl's exit code past shasum, which succeeds on anything.
    curl -sfL "$url" | shasum -a 256 | cut -d' ' -f1
}

for ARCH in arm64 x86_64; do
    echo "  fetching ${ARCH}..."
    if ! DIGEST=$(checksum_of "$ARCH") || [[ -z "$DIGEST" ]]; then
        echo "No ${ARCH} DMG published for v${VERSION}."
        echo "Both architectures have to be uploaded before the tap can be bumped."
        exit 1
    fi
    echo "  ${ARCH}  ${DIGEST}"
    if [[ "$ARCH" == "arm64" ]]; then SHA_ARM="$DIGEST"; else SHA_INTEL="$DIGEST"; fi
done

WORKTREE=$(mktemp -d)
trap 'rm -rf "$WORKTREE"' EXIT
gh repo clone "$TAP" "$WORKTREE" -- --quiet --depth 1

cat > "${WORKTREE}/${CASK_PATH}" <<CASK
cask "opensuperwhisper" do
  arch arm: "arm64", intel: "x86_64"

  version "${VERSION}"

  on_arm do
    sha256 "${SHA_ARM}"
  end
  on_intel do
    sha256 "${SHA_INTEL}"
  end

  url "https://github.com/${REPO}/releases/download/v#{version}/OpenSuperWhisper-#{arch}-#{version}.dmg"
  name "OpenSuperWhisper"
  desc "macOS dictation with local Whisper/Parakeet transcription"
  homepage "https://github.com/${REPO}"

  depends_on macos: :sonoma

  app "OpenSuperWhisper.app"
  binary "#{appdir}/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper", target: "opensuperwhisper"

  zap trash: [
    "~/Library/Application Support/fr.my-monkey.opensuperwhisper",
    "~/Library/Preferences/fr.my-monkey.opensuperwhisper.plist",
    "~/Library/Caches/fr.my-monkey.opensuperwhisper",
    "~/Library/Application Support/FluidAudio",
  ]
end
CASK

cd "$WORKTREE"
if git diff --quiet; then
    echo "The cask already says this. Nothing to push."
    exit 0
fi

git diff --stat
git add "$CASK_PATH"
git commit -q -m "opensuperwhisper ${VERSION}"
git push -q origin HEAD
echo "Tap updated: https://github.com/${TAP}/blob/main/${CASK_PATH}"
