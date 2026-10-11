import SwiftUI
import OpenSuperWhisperCore

/// Settings › Privacy: what is written to disk, how long it stays, and where to find the one
/// setting that reads the screen.
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
    ]

    var body: some View {
        RubricPage(.privacy, intro: "What OpenSuperWhisper keeps on your Mac, and for how long.", hasAdvanced: false) {
            historyGroup
            retentionGroup
            contextGroup
        }
    }

    private var historyGroup: some View {
        SettingsGroup("History") {
            SettingRow("Save transcription history",
                       hint: "Off, nothing is ever written to disk. Only the current transcription stays in memory for pasting.") {
                SSwitch(isOn: $viewModel.saveTranscriptionHistory)
            }
            SettingRow("Transcriptions folder", hint: LocalizedStringKey(Recording.recordingsDirectory.path)) {
                Button("Show in Finder") { NSWorkspace.shared.open(Recording.recordingsDirectory) }
                    .buttonStyle(.sSecondary)
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

    /// The setting itself lives in Text & AI, next to the model it feeds; privacy-minded people
    /// look for it here.
    private var contextGroup: some View {
        SettingsGroup("On-screen context") {
            SettingRow("Text around the cursor",
                       hint: viewModel.useSurroundingTextAsContext
                        ? "On: the model reads the sentence before your cursor. It stays on your Mac and is never saved."
                        : "Off: nothing on screen is read.") {
                Button("Open in Text & AI") {
                    AppNavigation.shared.openSettings(.textAndAI, focusing: "Use the text around the cursor")
                }
                .buttonStyle(.sSecondary)
            }
        }
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
