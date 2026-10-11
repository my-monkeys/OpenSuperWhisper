import SwiftUI

/// The update check and the release-note history pulled from GitHub Releases, shared by the
/// Help & what's new card, Settings › General and the old Updates tab.
@MainActor
final class ReleaseNotesModel: ObservableObject {
    @Published private(set) var releases: [GitHubRelease] = []
    @Published private(set) var isChecking = false
    @Published private(set) var availableUpdate: GitHubRelease?
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    func loadReleases() async {
        guard releases.isEmpty else { return }
        releases = (try? await UpdateChecker.fetchReleases()) ?? []
    }

    func checkForUpdates() async {
        isChecking = true
        errorMessage = nil
        statusMessage = nil
        availableUpdate = nil
        defer { isChecking = false }
        do {
            let fetched = try await UpdateChecker.fetchReleases()
            releases = fetched
            if let update = UpdateChecker.availableUpdate(in: fetched) {
                availableUpdate = update
            } else {
                statusMessage = "You're on the latest version."
            }
        } catch {
            errorMessage = "Couldn't check for updates. Check your connection and try again."
        }
    }

    /// Install in place via Sparkle (download, verify, relaunch), not a web page.
    func installUpdate() {
        SparkleUpdater.shared.checkForUpdates()
    }

    /// Render the markdown release notes, keeping line breaks (inline markdown only).
    /// Header markers ("## ") are stripped since SwiftUI's inline markdown shows them literally.
    static func renderedNotes(_ markdown: String) -> AttributedString {
        let cleaned = markdown.replacingOccurrences(
            of: "(?m)^#{1,6}[ \\t]+", with: "", options: .regularExpression)
        return (try? AttributedString(
            markdown: cleaned,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cleaned)
    }
}
