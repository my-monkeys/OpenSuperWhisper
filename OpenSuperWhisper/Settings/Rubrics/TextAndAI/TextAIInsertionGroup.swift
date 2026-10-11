import SwiftUI
import OpenSuperWhisperCore

/// How the finished text reaches the app: pasted or typed, what happens to the clipboard, and
/// the small rules applied on the way.
struct TextAIInsertionGroup: View {
    @ObservedObject var viewModel: SettingsViewModel

    private static let defaultRestoreDelayMs = 500.0

    var body: some View {
        SettingsGroup("Insertion") {
            SettingRow("Paste automatically", hint: "Into the app where your cursor is.") {
                SSwitch(isOn: $viewModel.autoPasteTranscription)
            }
            SettingRow("Method",
                       hint: "Paste sends one ⌘V, which suits Electron apps and Messages. Typing sends keystrokes and leaves the clipboard alone. Per-app exceptions override this.",
                       advanced: true) {
                SSegmented(selection: $viewModel.pasteInsteadOfTyping,
                           options: [(true, "Paste"), (false, "Simulate typing")])
            }
            SettingRow("Typing pace",
                       hint: "Pause between keystroke bursts. Raise it if a busy input box duplicates or misplaces text.",
                       advanced: true) {
                SSlider(value: typingPace,
                        range: 0...Double(TextInserter.maxChunkPauseMilliseconds),
                        valueLabel: "\(viewModel.typingPaceMilliseconds) ms")
            }
            SettingRow("Also keep it on the clipboard",
                       hint: "When off, what you had copied before is put back after the paste.") {
                SSwitch(isOn: $viewModel.autoCopyToClipboard)
            }
            if !viewModel.autoCopyToClipboard {
                SettingRow("Give the clipboard back after",
                           hint: "How long the dictation stays on the clipboard for the paste. Raise it if an app sometimes pastes your old item instead.",
                           badge: viewModel.clipboardRestoreDelayMs == Self.defaultRestoreDelayMs ? nil : ("Customized", .custom),
                           advanced: true, indented: true) {
                    SSlider(value: $viewModel.clipboardRestoreDelayMs.rubricSnapped(to: 50),
                            range: Double(AppPreferences.clipboardRestoreDelayRange.lowerBound)...Double(AppPreferences.clipboardRestoreDelayRange.upperBound),
                            valueLabel: "\(Int(viewModel.clipboardRestoreDelayMs)) ms")
                }
            }
            SettingRow("Warn when no field is focused",
                       hint: "Shows “Copied, press ⌘V” when no text field has the focus.") {
                SSwitch(isOn: $viewModel.notifyWhenNoPasteTarget)
            }
            SettingRow("“press enter” sends",
                       hint: "Saying “press enter” at the end presses Return, to send in Claude Code, Slack and the like.",
                       advanced: true) {
                SSwitch(isOn: $viewModel.submitOnVoiceCommand)
            }
            SettingRow("Space between dictations",
                       hint: "Leaves a space after a dictation that ends in punctuation, so the next one into the same field doesn't run into it.",
                       advanced: true) {
                SSwitch(isOn: $viewModel.addSpaceAfterSentence)
            }
            whisperRows
            SettingRow("Per-app exceptions", hint: perAppHint, advanced: true) {
                Button("Open →") {
                    AppNavigation.shared.closeSettings()
                    AppNavigation.shared.go(.style)
                }
                .buttonStyle(.sSecondary)
            }
        }
    }

    /// Two Whisper decoding options that used to sit with the delivery settings. Worded for what
    /// they do in the engine: neither touches the insertion itself.
    @ViewBuilder private var whisperRows: some View {
        SettingRow("Suppress blank output",
                   hint: "Stops the model from starting a passage with a blank. On by default.",
                   badge: ("Whisper", .engine), advanced: true) {
            SSwitch(isOn: $viewModel.suppressBlankAudio)
        }
        SettingRow("Add timestamps",
                   hint: "Starts each passage with its time, like [0.0->2.4], in dictations as well as transcribed files.",
                   badge: ("Whisper", .engine), advanced: true) {
            SSwitch(isOn: $viewModel.showTimestamps)
        }
    }

    private var perAppHint: LocalizedStringKey {
        let count = viewModel.appInsertionRules.count
        return count == 0
            ? "None yet. Set on the Style page, under Per app."
            : "\(count) apps. Set on the Style page, under Per app."
    }

    private var typingPace: Binding<Double> {
        Binding(get: { Double(viewModel.typingPaceMilliseconds) },
                set: { viewModel.typingPaceMilliseconds = Int($0.rounded()) })
    }
}
