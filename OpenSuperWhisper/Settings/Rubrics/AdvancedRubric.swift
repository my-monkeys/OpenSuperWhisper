import SwiftUI
import OpenSuperWhisperCore

/// Settings › Advanced: Whisper's decoding knobs, the post-record hook and debug logging. Every
/// row here is for experts already, so none hides behind the Advanced switch.
struct AdvancedRubric: View {
    @ObservedObject var viewModel: SettingsViewModel

    static let searchEntries: [SettingsSearchEntry] = [
        .init(title: "Use beam search", rubric: .advanced,
              keywords: "beam search decoding whisper décodage recherche en faisceau précision"),
        .init(title: "Beam size", rubric: .advanced,
              keywords: "beam size whisper taille du faisceau"),
        .init(title: "Temperature", rubric: .advanced,
              keywords: "temperature randomness whisper température aléatoire"),
        .init(title: "No speech threshold", rubric: .advanced,
              keywords: "silence threshold whisper seuil silence parole"),
        .init(title: "Run a command after each transcription", rubric: .advanced,
              keywords: "post-record hook script shell command commande script après transcription"),
        .init(title: "Debug mode", rubric: .advanced,
              keywords: "debug logs logging diagnostic journaux débogage"),
    ]

    private static let whisperBadge: (LocalizedStringKey, SBadgeKind) = ("Whisper", .engine)

    var body: some View {
        RubricPage(.advanced, intro: "Decoding, scripts and logs, for those who like to tinker.", hasAdvanced: false) {
            decodingGroup
            parametersGroup
            hookGroup
            SettingsGroup("Debug") {
                SettingRow("Debug mode", hint: "Extra logging and diagnostic output.") {
                    SSwitch(isOn: $viewModel.debugMode)
                }
            }
        }
    }

    private var decodingGroup: some View {
        SettingsGroup("Decoding") {
            SettingRow("Use beam search", hint: "Can improve accuracy, at some speed cost.", badge: Self.whisperBadge) {
                SSwitch(isOn: $viewModel.useBeamSearch)
            }
            if viewModel.useBeamSearch {
                SettingRow("Beam size", indented: true) {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(viewModel.beamSize)")
                            .scaledFont(size: 13, weight: .semibold, design: .monospaced)
                            .foregroundColor(STheme.textBright)
                            .frame(minWidth: 24, alignment: .trailing)
                        Stepper("", value: $viewModel.beamSize, in: 1...10)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private var parametersGroup: some View {
        SettingsGroup("Model parameters") {
            SettingRow("Temperature", hint: "Higher values make decoding more random.", badge: Self.whisperBadge,
                       stacked: true) {
                SSlider(value: $viewModel.temperature, range: 0...1, step: 0.1,
                        valueLabel: String(format: "%.2f", viewModel.temperature))
            }
            SettingRow("No speech threshold", hint: "How confident the model must be to call a segment silence.",
                       badge: Self.whisperBadge, stacked: true) {
                SSlider(value: $viewModel.noSpeechThreshold, range: 0...1, step: 0.1,
                        valueLabel: String(format: "%.2f", viewModel.noSpeechThreshold))
            }
        }
    }

    private var hookGroup: some View {
        SettingsGroup("Post-record hook") {
            SettingRow("Run a command after each transcription",
                       hint: "Launch your own script when a transcription completes.") {
                HStack(spacing: 10) {
                    InfoButton(text: "Runs via /bin/sh -c after each successful transcription, in the background. Your command receives the data as environment variables — OSW_TEXT, OSW_RAW_TEXT, OSW_APP_BUNDLE_ID, OSW_AUDIO_PATH (when history is on), OSW_TIMESTAMP, OSW_DURATION — and a JSON object on stdin with the same fields. Example: echo \"$OSW_TEXT\" >> ~/dictations.txt")
                    SSwitch(isOn: $viewModel.postRecordHookEnabled)
                }
            }
            if viewModel.postRecordHookEnabled {
                VStack(alignment: .leading, spacing: 12) {
                    HookCommandEditor(text: $viewModel.postRecordHookCommand)
                    hookVariables
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)
            }
        }
    }

    private var hookVariables: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Available in your command (also piped as JSON on stdin):")
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(SettingsView.postRecordHookVariables, id: \.name) { variable in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: variable.name)
                        .scaledFont(size: 12, weight: .medium, design: .monospaced)
                        .foregroundColor(STheme.textBright)
                    Text(LocalizedStringKey(variable.description))
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The hook's shell command, monospaced, in the redesign's input style.
private struct HookCommandEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .scaledFont(size: 13, design: .monospaced)
            .foregroundColor(STheme.textBright)
            .scrollContentBackground(.hidden)
            .autocorrectionDisabled(true)
            .padding(8)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
    }
}
