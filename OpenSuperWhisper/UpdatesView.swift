import SwiftUI

/// The "Updates" settings tab (Settings Explorations 2f): shows the current version, a manual
/// update check, and the release-note history pulled from GitHub Releases.
struct UpdatesView: View {
    @State private var releases: [GitHubRelease] = []
    @State private var isChecking = false
    @State private var availableUpdate: GitHubRelease?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        SPane(title: "Updates") {
            versionSection
            whatsNewSection
        }
        .task { await loadReleases() }
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let update = availableUpdate {
                updateBanner(update)
            }
            SRow(title: "OpenSuperWhisper \(UpdateChecker.currentVersion)",
                 hint: "Updates install in place, then the app relaunches.") {
                Button(action: { Task { await checkForUpdates() } }) {
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .controlSize(.small)
                .disabled(isChecking)
            }
            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(STheme.ok)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
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
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(STheme.textBright)
                // The release page on GitHub, for those who want to read it first.
                Button("View on GitHub") { NSWorkspace.shared.open(update.htmlURL) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Spacer()
            // Install in place via Sparkle (download + verify + relaunch), not a web page.
            Button("Install Update") { SparkleUpdater.shared.checkForUpdates() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(STheme.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(STheme.accent.opacity(0.35), lineWidth: 1))
    }

    private var whatsNewSection: some View {
        SSection(title: "What's new") {
            if releases.isEmpty {
                Text("Loading release notes…")
                    .font(.system(size: 11))
                    .foregroundColor(STheme.hint)
            } else {
                ForEach(releases) { release in
                    releaseRow(release)
                }
            }
        }
    }

    private func releaseRow(_ release: GitHubRelease) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(release.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(STheme.textBright)
                Spacer()
                if let date = release.publishedAt {
                    Text(date, style: .date)
                        .font(.system(size: 11))
                        .foregroundColor(STheme.hint)
                }
            }
            if let body = release.body, !body.isEmpty {
                Text(renderedNotes(body))
                    .font(.system(size: 12))
                    .foregroundColor(STheme.text.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(STheme.border).frame(height: 1).padding(.top, 6)
        }
    }

    /// Render the markdown release notes, keeping line breaks (inline markdown only).
    /// Header markers ("## ") are stripped since SwiftUI's inline markdown shows them literally.
    private func renderedNotes(_ markdown: String) -> AttributedString {
        let cleaned = markdown.replacingOccurrences(
            of: "(?m)^#{1,6}[ \\t]+", with: "", options: .regularExpression)
        return (try? AttributedString(
            markdown: cleaned,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cleaned)
    }

    private func loadReleases() async {
        guard releases.isEmpty else { return }
        releases = (try? await UpdateChecker.fetchReleases()) ?? []
    }

    private func checkForUpdates() async {
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
}
