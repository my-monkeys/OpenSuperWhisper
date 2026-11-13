import SwiftUI
import OpenSuperWhisperCore

/// Settings › General › Backup and sync: a settings file to export and import, and the same file
/// kept in a secret gist for moving between Macs.
struct SettingsTransferGroup: View {
    @StateObject private var model = SettingsTransferModel()
    @StateObject private var icloud = ICloudBackupModel()

    var body: some View {
        SettingsGroup("Backup and sync") {
            SettingRow("Settings file",
                       hint: "Your preferences, dictionary and snippets in one file. API keys stay in this Mac's Keychain.") {
                HStack(spacing: 8) {
                    Button("Export…") { model.exportFile() }
                    Button("Import…") { model.importFile() }
                }
                .buttonStyle(.sSecondary)
                .disabled(model.isBusy)
            }
            iCloudRows
            githubRow
            notices
        }
        .onAppear {
            model.refreshGitHub()
            Task { await icloud.refresh() }
        }
        .confirmationDialog("A backup from another Mac is in iCloud Drive", isPresented: Binding(
            get: { icloud.conflict != nil },
            set: { if !$0 { icloud.conflict = nil } })) {
            Button("Restore it") { Task { await restoreFromConflict() } }
            Button("Replace it with this Mac's settings") { Task { await icloud.replaceBackup() } }
            Button("Cancel", role: .cancel) { icloud.conflict = nil }
        } message: {
            Text(conflictMessage)
        }
        .confirmationDialog(importTitle, isPresented: Binding(
            get: { model.pendingImport != nil },
            set: { if !$0 { model.pendingImport = nil } })) {
            Button("Replace my settings") { model.confirmImport() }
            Button("Cancel", role: .cancel) { model.pendingImport = nil }
        } message: {
            Text("Settings that are not in the file stay as they are. A relaunch applies the new ones.")
        }
    }

    @ViewBuilder
    private var iCloudRows: some View {
        SettingRow("Back up to iCloud Drive", hint: iCloudHint) {
            SSwitch(isOn: Binding(
                get: { icloud.isEnabled },
                set: { on in Task { await icloud.setEnabled(on) } }))
                .disabled(!icloud.isAvailable)
        }
        if icloud.isAvailable {
            SettingRow("Restore from iCloud Drive", hint: lastBackupHint) {
                Button("Restore…") {
                    Task {
                        if let pending = await icloud.restoreRequest() { model.pendingImport = pending }
                    }
                }
                .buttonStyle(.sSecondary)
                .disabled(model.isBusy || icloud.lastBackup == nil)
            }
            if let error = icloud.errorMessage { SettingNotice(LocalizedStringKey(error)) }
        }
    }

    private var iCloudHint: LocalizedStringKey {
        icloud.isAvailable
            ? "Keeps your settings up to date in iCloud Drive, to restore on another Mac. Nothing is sent to other Macs on its own."
            : "iCloud Drive is off on this Mac. Turn it on in System Settings to use this."
    }

    private var lastBackupHint: LocalizedStringKey {
        if icloud.isDownloading { return "Downloading the backup from iCloud…" }
        guard let last = icloud.lastBackup, let date = last.exportedAt else { return "No backup in iCloud Drive yet." }
        let when = date.formatted(.relative(presentation: .named))
        guard let host = last.host else { return "Last backup: \(when)" }
        return "Last backup: \(when) from \(host)"
    }

    private var conflictMessage: LocalizedStringKey {
        guard let host = icloud.conflict?.host else { return "Restore it to use those settings here, or replace it with this Mac's." }
        return "\(host) already saved its settings there. Restore them here, or replace them with this Mac's."
    }

    private func restoreFromConflict() async {
        guard let pending = await icloud.restoreFromConflict() else { return }
        model.pendingImport = pending
        model.confirmImport()
    }

    @ViewBuilder
    private var githubRow: some View {
        switch model.github {
        case .signedOut:
            SettingRow("GitHub sync", hint: "Keeps a copy in a secret gist on your GitHub account, to fetch on another Mac.") {
                Button("Sign in with GitHub") { model.signIn() }
                    .buttonStyle(.sSecondary)
            }
        case .signingIn(let code):
            SettingRow("GitHub sync", hint: "Enter this code on github.com, then come back here.") {
                Text(code.userCode)
                    .scaledFont(size: 15, weight: .semibold)
                    .monospaced()
                    .textSelection(.enabled)
            }
            SettingNotice("Waiting for GitHub…") {
                HStack(spacing: 8) {
                    Button("Cancel") { model.cancelSignIn() }
                        .buttonStyle(.sSecondary)
                    Button("Copy code and open GitHub") { model.copyCodeAndOpenGitHub() }
                        .buttonStyle(.sPrimary)
                }
            }
        case .signedIn(let login):
            SettingRow("GitHub sync", hint: signedInHint(login), stacked: true) {
                HStack(spacing: 8) {
                    Button("Send") { model.send() }
                    Button("Fetch") { model.fetch() }
                    Button("Sign out") { model.signOut() }
                        .buttonStyle(.sQuiet)
                    Spacer(minLength: 12)
                    lastSentLabel
                }
                .buttonStyle(.sSecondary)
                .disabled(model.isBusy)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if model.needsRelaunch {
            SettingNotice("Settings imported. Relaunch to apply them.") {
                Button("Relaunch now") { LanguageManager.relaunch() }
                    .buttonStyle(.sPrimary)
            }
        } else if let error = model.errorMessage {
            SettingNotice(LocalizedStringKey(error))
        } else if let status = model.status {
            SettingNotice(status)
        }
    }

    /// Re-rendered every minute so "2 minutes ago" does not freeze while Settings stays open.
    private var lastSentLabel: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Group {
                if let date = model.lastSentAt {
                    Text("Last sent \(date.formatted(.relative(presentation: .named)))")
                        .help(date.formatted(date: .long, time: .shortened))
                } else {
                    Text("Never sent")
                }
            }
            .scaledFont(size: 12)
            .foregroundColor(STheme.textSecondary)
            .lineLimit(1)
        }
    }

    private func signedInHint(_ login: String) -> LocalizedStringKey {
        login.isEmpty
            ? "Send saves this Mac's settings to your gist. Fetch replaces them with the saved copy."
            : "Signed in as @\(login). Send saves this Mac's settings to your gist. Fetch replaces them with the saved copy."
    }

    private var importTitle: LocalizedStringKey {
        guard let savedAt = model.pendingImport?.savedAt else { return "Replace your settings with this file?" }
        if let host = model.pendingImport?.host {
            return "Replace your settings with the backup from \(host), saved \(savedAt.formatted(.relative(presentation: .named)))?"
        }
        return "Replace your settings with the copy saved \(savedAt.formatted(.relative(presentation: .named)))?"
    }
}
