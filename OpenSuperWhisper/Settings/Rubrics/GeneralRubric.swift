import SwiftUI
import OpenSuperWhisperCore

/// Settings › General: the interface language, how the app starts, and updates.
struct GeneralRubric: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @StateObject private var updates = ReleaseNotesModel()
    @State private var appLanguage = LanguageManager.selected
    @State private var languageNeedsRelaunch = false

    static let searchEntries: [SettingsSearchEntry] = [
        .init(title: "App language", rubric: .general,
              keywords: "language interface locale langue interface traduction"),
        .init(title: "Open at login", rubric: .general,
              keywords: "launch at login startup démarrage ouvrir à la connexion session"),
        .init(title: "Start in the menu bar", rubric: .general,
              keywords: "hidden menu bar barre des menus démarrer caché fenêtre"),
        .init(title: "Version", rubric: .general,
              keywords: "update check sparkle release mise à jour version nouveautés"),
    ]

    /// Language names are written in their own language, so they stay as they are.
    private static let languages: [(value: String, label: LocalizedStringKey)] = [
        ("system", "System"),
        ("en", "English"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("it", "Italiano"),
        ("pt-BR", "Português (BR)"),
        ("vi", "Tiếng Việt"),
    ]

    var body: some View {
        RubricPage(.general, intro: "How the app starts and which language it speaks.", hasAdvanced: false) {
            languageGroup
            startupGroup
            updatesGroup
        }
        .onAppear { launchAtLogin.refresh() }
        .onChange(of: appLanguage) { _, newValue in
            LanguageManager.selected = newValue
            languageNeedsRelaunch = true
        }
    }

    private var languageGroup: some View {
        SettingsGroup("Language") {
            SettingRow("App language", hint: "The language of menus and settings. Relaunch to apply.") {
                SPicker(selection: $appLanguage, options: Self.languages)
            }
            if languageNeedsRelaunch {
                SettingNotice("Relaunch to apply the new language.") {
                    Button("Relaunch now") { LanguageManager.relaunch() }
                        .buttonStyle(.sPrimary)
                }
            }
        }
    }

    private var startupGroup: some View {
        SettingsGroup("Startup") {
            SettingRow("Open at login", hint: "Start OpenSuperWhisper automatically when you log in.") {
                SSwitch(isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }))
            }
            SettingRow("Start in the menu bar",
                       hint: "Launch without the main window. Open it from the menu bar icon.") {
                SSwitch(isOn: $viewModel.startHidden)
            }
        }
    }

    private var updatesGroup: some View {
        SettingsGroup("Updates") {
            // Stacked: two buttons beside the version sentence squeeze it to a word per line at
            // the largest text size.
            SettingRow("Version",
                       hint: "OpenSuperWhisper \(UpdateChecker.currentVersion). Updates install in place, then the app relaunches.",
                       stacked: true) {
                HStack(spacing: 14) {
                    checkButton
                    Button("What's new") {
                        AppNavigation.shared.closeSettings()
                        AppNavigation.shared.helpOpen = true
                    }
                    .buttonStyle(.plain)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.accent)
                    .fixedSize()
                }
            }
            if let update = updates.availableUpdate {
                SettingNotice("Update available: \(update.tagName)") {
                    Button("Install update") { updates.installUpdate() }
                        .buttonStyle(.sPrimary)
                }
            } else if let message = updates.statusMessage {
                SettingNotice(LocalizedStringKey(message))
            } else if let message = updates.errorMessage {
                SettingNotice(LocalizedStringKey(message))
            }
        }
    }

    private var checkButton: some View {
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
}
