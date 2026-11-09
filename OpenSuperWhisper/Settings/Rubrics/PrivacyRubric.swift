import SwiftUI
import OpenSuperWhisperCore

/// Settings › Privacy: what is written to disk, how long it stays, and where to find the
/// settings that read the screen.
struct PrivacyRubric: View {
    @ObservedObject var viewModel: SettingsViewModel

    static let searchEntries: [SettingsSearchEntry] = [
        .init(title: "Save transcription history", rubric: .privacy,
              keywords: "history disk save historique enregistrer sauvegarder transcriptions"),
        .init(title: "Transcriptions folder", rubric: .privacy,
              keywords: "directory finder path dossier répertoire chemin transcriptions"),
        .init(title: "Limit number of recordings", rubric: .privacy,
              keywords: "retention maximum count conservation limite nombre enregistrements"),
        .init(title: "Keep at most", rubric: .privacy,
              keywords: "retention maximum count conservation garder au plus"),
        .init(title: "Delete old recordings", rubric: .privacy,
              keywords: "retention age cleanup conservation supprimer anciens enregistrements nettoyage"),
        .init(title: "Delete after", rubric: .privacy,
              keywords: "retention age days hours conservation supprimer après jours heures"),
        .init(title: "Text around the cursor", rubric: .privacy,
              keywords: "screen context cursor surrounding contexte écran curseur texte autour"),
        .init(title: "Match the text around the cursor", rubric: .privacy,
              keywords: "screen read field caret case period space écran lire champ curseur majuscule point espace"),
        .init(title: "Suggest words from your corrections", rubric: .privacy,
              keywords: "dictionary learn correction field read suggestion dictionnaire apprendre corriger champ lire"),
        .init(title: "Send crash reports", rubric: .privacy,
              keywords: "crash report diagnostics stack send telemetry rapport plantage diagnostic envoyer"),
    ]

    var body: some View {
        RubricPage(.privacy, intro: "What OpenSuperWhisper keeps on your Mac, and for how long.", hasAdvanced: false) {
            historyGroup
            retentionGroup
            contextGroup
            diagnosticsGroup
        }
    }

    /// A crash report leaves this Mac, so the choice is the person's. What it never carries is
    /// spelled out next to the setting, not buried in a policy.
    private var diagnosticsGroup: some View {
        SettingsGroup("Diagnostics") {
            SettingRow("Send crash reports", hint: crashReportHint) {
                SPicker(selection: $viewModel.crashReportMode,
                        options: CrashReportMode.allCases.map { ($0, LocalizedStringKey($0.title)) })
            }
        }
    }

    private var crashReportHint: LocalizedStringKey {
        switch viewModel.crashReportMode {
        case .ask:
            return "After a crash, OpenSuperWhisper asks before sending. A report says where the app stopped, its version and your macOS version. It never includes your dictations, your audio or your clipboard."
        case .auto:
            return "After a crash, a report is sent without asking. It says where the app stopped, its version and your macOS version, and never your dictations, your audio or your clipboard."
        case .off:
            return "Crashes are never reported."
        }
    }

    private var historyGroup: some View {
        SettingsGroup("History") {
            SettingRow("Save transcription history",
                       hint: "Off, nothing is ever written to disk. Only the current transcription stays in memory for pasting.") {
                SSwitch(isOn: $viewModel.saveTranscriptionHistory)
            }
            SettingRow("Transcriptions folder", hint: LocalizedStringKey(Recording.recordingsDirectory.path)) {
                // Under the button rather than beside it: the label and its long path take the
                // row's width first, and beside the button the weight was squeezed into a
                // column a few letters wide.
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Show in Finder") { NSWorkspace.shared.open(Recording.recordingsDirectory) }
                        .buttonStyle(.sSecondary)
                    RecordingsSizeText(style: .sizeAndCount)
                        .scaledFont(size: 12)
                        .foregroundColor(STheme.hint)
                        .fixedSize()
                }
            }
        }
    }

    private var retentionGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsGroup("Retention") {
                SettingRow("Limit number of recordings",
                           hint: "Keep only the most recent recordings and transcriptions.") {
                    SSwitch(isOn: $viewModel.retentionMaxCountEnabled)
                }
                if viewModel.retentionMaxCountEnabled {
                    SettingRow("Keep at most", indented: true) {
                        HStack(spacing: 8) {
                            RetentionNumberField(value: $viewModel.retentionMaxCount)
                            Text("recordings")
                                .scaledFont(size: 13)
                                .foregroundColor(STheme.hint)
                                .fixedSize()
                        }
                    }
                }
                SettingRow("Delete old recordings",
                           hint: "Automatically remove recordings older than the chosen age.") {
                    SSwitch(isOn: $viewModel.retentionMaxAgeEnabled)
                }
                if viewModel.retentionMaxAgeEnabled {
                    SettingRow("Delete after", indented: true) {
                        HStack(spacing: 8) {
                            RetentionNumberField(value: $viewModel.retentionMaxAgeValue)
                            SPicker(selection: $viewModel.retentionMaxAgeUnit,
                                    options: RetentionUnit.allCases.map { ($0, LocalizedStringKey($0.displayName)) })
                        }
                    }
                }
            }
            Text("Both limits combine: whichever is hit first wins. Cleanup runs on its own, never while a transcription is being processed.")
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The settings that read the field live next to what they feed, two in Text & AI and one
    /// on the Dictionary page; privacy-minded people look for them here. Each row says only what
    /// its own setting reads, and "nothing on screen is read" only when none does.
    private var contextGroup: some View {
        SettingsGroup("On-screen context") {
            SettingRow("Text around the cursor", hint: modelContextHint) {
                Button("Open in Text & AI") {
                    AppNavigation.shared.openSettings(.textAndAI, focusing: "Use the text around the cursor")
                }
                .buttonStyle(.sSecondary)
            }
            SettingRow("Match the text around the cursor", hint: caretMatchHint) {
                Button("Open in Text & AI") {
                    AppNavigation.shared.openSettings(.textAndAI, focusing: "Match the text around the cursor")
                }
                .buttonStyle(.sSecondary)
            }
            SettingRow("Suggest words from your corrections", hint: suggestionsHint) {
                Button("Open the Dictionary") {
                    AppNavigation.shared.showDashboard(.dictionary)
                }
                .buttonStyle(.sSecondary)
            }
        }
    }

    /// It only reads anything while the dictionary is on too.
    private var watchesCorrections: Bool {
        viewModel.suggestDictionaryWords && viewModel.customDictionaryEnabled
    }

    private var suggestionsHint: LocalizedStringKey {
        watchesCorrections
            ? "On: after a dictation, the field it went into is read again for up to a minute to spot the words you correct. Each word you are offered is kept with what was heard, until you answer or turn this off."
            : "Off: the field is not read after a dictation."
    }

    private var modelContextHint: LocalizedStringKey {
        if viewModel.useSurroundingTextAsContext {
            return "On: the model reads the sentence before your cursor. It stays on your Mac and is never saved."
        }
        return viewModel.matchTextAroundCaret || watchesCorrections
            ? "Off: the model is given nothing from the screen."
            : "Off: nothing on screen is read."
    }

    private var caretMatchHint: LocalizedStringKey {
        viewModel.matchTextAroundCaret
            ? "On: the field is read just before inserting, to fit the case, final period and spaces. It stays in memory for that one insertion and is never saved."
            : "Off: the field is not read before inserting."
    }
}

/// A number typed or stepped, 1 to 100 000, for the retention limits.
private struct RetentionNumberField: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.plain)
                .scaledFont(size: 13, design: .monospaced)
                .foregroundColor(STheme.textBright)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(width: 76)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
            Stepper("", value: $value, in: 1...100000)
                .labelsHidden()
        }
    }
}
