import SwiftUI
import OpenSuperWhisperCore

/// Help & what's new, as a card over the main window: the update check, where to send a bug or
/// an idea, how to support the project, and the release notes.
struct HelpOverlay: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var navigation = AppNavigation.shared
    @StateObject private var updates = ReleaseNotesModel()

    private static let repository = "https://github.com/my-monkeys/OpenSuperWhisper"

    var body: some View {
        ModalCard(maxWidth: 760, onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 18)
                ScrollView {
                    SPaneStack(spacing: 26) {
                        updatesGroup
                        feedbackGroup
                        supportGroup
                        releasesGroup
                    }
                    .padding(.horizontal, 32).padding(.bottom, 32)
                }
            }
        }
        .task { await updates.loadReleases() }
    }

    private func close() { navigation.helpOpen = false }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Help & what's new")
                    .scaledFont(size: 26, weight: .bold)
                    .foregroundColor(STheme.textBright)
                Text("Updates, release notes, and where to tell us what works and what doesn't.")
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            CloseButton(action: close)
        }
    }

    // MARK: Updates

    private var updatesGroup: some View {
        SettingsGroup("Updates") {
            if let update = updates.availableUpdate {
                SettingNotice("Update available: \(update.tagName)") {
                    HStack(spacing: 8) {
                        // The release page on GitHub, for those who want to read it first.
                        Button("View on GitHub") { NSWorkspace.shared.open(update.htmlURL) }
                            .buttonStyle(.sSecondary)
                        Button("Install update") { updates.installUpdate() }
                            .buttonStyle(.sPrimary)
                    }
                }
            }
            SettingRow("Version",
                       hint: "OpenSuperWhisper \(UpdateChecker.currentVersion). Updates install in place, then the app relaunches.") {
                Button {
                    Task { await updates.checkForUpdates() }
                } label: {
                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check for updates")
                    }
                }
                .buttonStyle(.sSecondary)
                .disabled(updates.isChecking)
            }
            if let message = updates.statusMessage {
                HelpMessageRow(text: LocalizedStringKey(message), symbol: "checkmark.circle.fill", color: STheme.ok)
            }
            if let message = updates.errorMessage {
                HelpMessageRow(text: LocalizedStringKey(message), symbol: "exclamationmark.triangle.fill", color: STheme.warn)
            }
        }
    }

    // MARK: Feedback and support

    private var feedbackGroup: some View {
        SettingsGroup("Feedback", subtitle: "Every report makes the app more stable.") {
            HelpLinkRow(title: "Report a bug",
                        subtitle: "On GitHub. Steps to reproduce, your macOS version and engine, logs if you have them.",
                        symbol: "ladybug",
                        url: "\(Self.repository)/issues/new")
            HelpLinkRow(title: "Send feedback or an idea",
                        subtitle: "A quick form on opensuperwhisper.com, no account needed.",
                        symbol: "bubble.left.and.bubble.right",
                        url: "https://opensuperwhisper.com/#feedback")
            HelpLinkRow(title: "Try a beta build",
                        subtitle: "Early features before they ship, on GitHub Releases.",
                        symbol: "testtube.2",
                        url: "\(Self.repository)/releases")
        }
    }

    private var supportGroup: some View {
        SettingsGroup("Support") {
            HelpLinkRow(title: "Support us",
                        subtitle: "OpenSuperWhisper is free and open source. A coffee on Ko-fi keeps it going.",
                        symbol: "heart",
                        url: "https://ko-fi.com/mymonkey")
            HelpLinkRow(title: "Source code on GitHub",
                        subtitle: "Version \(UpdateChecker.currentVersion). Star it, read it, open a pull request.",
                        symbol: "chevron.left.forwardslash.chevron.right",
                        url: Self.repository)
        }
    }

    // MARK: Release notes

    private var releasesGroup: some View {
        SettingsGroup("What's new") {
            if updates.releases.isEmpty {
                HelpMessageRow(text: "Loading release notes…", symbol: "clock", color: STheme.hint)
            } else {
                ForEach(updates.releases) { release in
                    ReleaseRow(release: release)
                }
            }
        }
    }
}

/// A whole-row link out of the app: icon, title, one sentence, and the ↗ that says it leaves.
private struct HelpLinkRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let url: String

    var body: some View {
        Button {
            if let target = URL(string: url) { NSWorkspace.shared.open(target) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundColor(STheme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                    Text(subtitle)
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundColor(STheme.hint)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }
}

/// One line of feedback inside a group: the result of the update check, or a loading state.
private struct HelpMessageRow: View {
    let text: LocalizedStringKey
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(size: 13)
            Text(text)
                .scaledFont(size: 13)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(color)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }
}

/// A release: its name and date, then its notes.
private struct ReleaseRow: View {
    let release: GitHubRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: release.displayName)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                Spacer(minLength: 0)
                if let date = release.publishedAt {
                    Text(date, style: .date)
                        .scaledFont(size: 12)
                        .foregroundColor(STheme.hint)
                }
            }
            if let body = release.body, !body.isEmpty {
                Text(ReleaseNotesModel.renderedNotes(body))
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }
}
