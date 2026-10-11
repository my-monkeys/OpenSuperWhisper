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

/// The "Updates" settings tab (Settings Explorations 2f): shows the current version, a manual
/// update check, and the release-note history pulled from GitHub Releases.
struct UpdatesView: View {
    @StateObject private var model = ReleaseNotesModel()

    var body: some View {
        SPane(title: "Updates") {
            versionSection
            whatsNewSection
        }
        .task { await model.loadReleases() }
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let update = model.availableUpdate {
                updateBanner(update)
            }
            SRow(title: "OpenSuperWhisper \(UpdateChecker.currentVersion)",
                 hint: "Updates install in place, then the app relaunches.") {
                Button(action: { Task { await model.checkForUpdates() } }) {
                    if model.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .controlSize(.small)
                .disabled(model.isChecking)
            }
            if let statusMessage = model.statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .scaledFont(size: 11)
                    .foregroundColor(STheme.ok)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .scaledFont(size: 11)
                    .foregroundColor(.red)
            }
        }
    }

    private func updateBanner(_ update: GitHubRelease) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(STheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available: \(update.tagName)")
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                // The release page on GitHub, for those who want to read it first.
                Button("View on GitHub") { NSWorkspace.shared.open(update.htmlURL) }
                    .buttonStyle(.link)
                    .scaledFont(size: 11)
            }
            Spacer()
            Button("Install Update") { model.installUpdate() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(STheme.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.accent.opacity(0.35), lineWidth: 1))
    }

    private var whatsNewSection: some View {
        SSection(title: "What's new") {
            if model.releases.isEmpty {
                Text("Loading release notes…")
                    .scaledFont(size: 11)
                    .foregroundColor(STheme.hint)
            } else {
                ForEach(model.releases) { release in
                    releaseRow(release)
                }
            }
        }
    }

    private func releaseRow(_ release: GitHubRelease) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(release.displayName)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                Spacer()
                if let date = release.publishedAt {
                    Text(date, style: .date)
                        .scaledFont(size: 11)
                        .foregroundColor(STheme.hint)
                }
            }
            if let body = release.body, !body.isEmpty {
                Text(ReleaseNotesModel.renderedNotes(body))
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.text.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(STheme.border).frame(height: 1).padding(.top, 6)
        }
    }
}
