import SwiftUI
import AppKit
import OpenSuperWhisperCore

/// Settings → Dictation: what starts and stops a dictation, the microphone and language, and
/// what the Mac does while you speak. The recording bar's look lives in Appearance.
struct DictationRubric: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var micService = MicrophoneService.shared
    /// The first trigger that is a modifier on its own (or a modifier chord). Those are read with
    /// an event tap, which needs Input Monitoring. Mirrored in state because the trigger lists
    /// live in preferences, which SwiftUI does not observe.
    @State private var modifierTrigger: String?

    static let searchEntries: [SettingsSearchEntry] = [
        .init(title: "To dictate", rubric: .dictation,
              keywords: "shortcut trigger hotkey key mouse button raccourci touche déclencheur bouton souris dicter"),
        .init(title: "Cancel dictation", rubric: .dictation,
              keywords: "escape esc abort discard annuler échap"),
        .init(title: "Hold-only shortcuts", rubric: .dictation, advanced: true,
              keywords: "push to talk hold maintenir appui long raccourci"),
        .init(title: "Hold to record", rubric: .dictation, advanced: true,
              keywords: "push to talk long press maintenir appui long"),
        .init(title: "Lock with Space", rubric: .dictation, advanced: true,
              keywords: "latch space hands-free verrouiller espace mains libres"),
        .init(title: "Dictate and send", rubric: .dictation, advanced: true,
              keywords: "submit return enter send envoyer entrée"),
        .init(title: "Paste the last dictation", rubric: .dictation, advanced: true,
              keywords: "paste last transcription again coller dernière dictée"),
        .init(title: "Confirm before cancelling", rubric: .dictation, advanced: true,
              keywords: "confirmation escape twice confirmer annuler"),
        .init(title: "Microphone", rubric: .dictation,
              keywords: "mic input device headset micro entrée casque"),
        .init(title: "Spoken language", rubric: .dictation,
              keywords: "language auto detect keyboard langue parlée clavier détection"),
        .init(title: "Translate to English", rubric: .dictation,
              keywords: "translation english traduction traduire anglais"),
        .init(title: "Sound at start and end", rubric: .dictation,
              keywords: "sound chime beep son bip"),
        .init(title: "Live text", rubric: .dictation,
              keywords: "live transcription preview streaming texte en direct aperçu parakeet"),
        .init(title: "Type directly into the app", rubric: .dictation, advanced: true,
              keywords: "stream insert cursor écrire directement curseur"),
        .init(title: "Pause music", rubric: .dictation,
              keywords: "media pause spotify music musique pause média"),
        .init(title: "Lower the Mac's volume", rubric: .dictation,
              keywords: "volume duck reduce baisser volume son"),
        .init(title: "Stop phrase", rubric: .dictation, advanced: true,
              keywords: "voice command over and out silence phrase de fin commande vocale"),
        .init(title: "Press Return after", rubric: .dictation, advanced: true,
              keywords: "submit enter return entrée envoyer phrase de fin"),
        .init(title: "Open and switch apps by voice", rubric: .dictation, advanced: true,
              keywords: "voice command open app ouvrir changer app voix"),
    ]

    var body: some View {
        RubricPage(.dictation, intro: "How you start a dictation, and what happens during it.") {
            shortcutsGroup
            microphoneGroup
            whileDictatingGroup
            voiceCommandsGroup
        }
        .onAppear(perform: refreshModifierTrigger)
        .onReceive(NotificationCenter.default.publisher(for: .hotkeySettingsChanged)) { _ in
            refreshModifierTrigger()
        }
    }

    // MARK: - Shortcuts

    private var shortcutsGroup: some View {
        SettingsGroup("Shortcuts") {
            SettingRow("To dictate", hint: viewModel.holdToRecord
                       ? "Short press: dictation starts and keeps going, press again to stop. Long press: it stops when you release."
                       : "Press to start a dictation, press again to stop.") {
                TriggerRecorderField(name: .toggleRecord,
                                     mouseButton: $viewModel.mouseButtonHotkey,
                                     modifierKey: $viewModel.modifierOnlyHotkey,
                                     allowsMultiple: true,
                                     style: .chips)
            }
            if let modifierTrigger {
                SettingNotice("\(modifierTrigger) on its own needs the Input Monitoring permission. Only modifier keys are read.") {
                    Button("Open macOS settings") { openPrivacyPane("Privacy_ListenEvent") }
                        .buttonStyle(.sDanger)
                }
            }
            SettingRow("Cancel dictation", hint: "Discards the recording in progress. Esc on its own works here.") {
                TriggerRecorderField(name: .escape,
                                     mouseButton: $viewModel.cancelMouseButtonUnused,
                                     modifierKey: $viewModel.cancelModifierUnused,
                                     allowsMouse: false,
                                     allowsModifier: false,
                                     allowsBareEscape: true,
                                     style: .chips)
            }
            SettingRow("Hold-only shortcuts",
                       hint: "These record only while held and stop when released, whatever Hold to record says. Pair a shortcut above with a held key here, like Right ⌥ Option.",
                       advanced: true) {
                TriggerRecorderField(name: .toggleRecord,
                                     mouseButton: $viewModel.mouseButtonHotkey,
                                     modifierKey: $viewModel.modifierOnlyHotkey,
                                     allowsMultiple: true,
                                     holdOnly: true,
                                     style: .chips)
            }
            SettingRow("Hold to record",
                       hint: "A long press on a shortcut records until you release it. Off, every press starts or stops.",
                       advanced: true) {
                SSwitch(isOn: $viewModel.holdToRecord)
            }
            SettingRow("Lock with Space",
                       hint: "While recording, Space (or a double tap of the shortcut) keeps it going so you can let go. Space again stops it.",
                       advanced: true) {
                SSwitch(isOn: $viewModel.latchRecordingWithSpace)
            }
            if viewModel.latchRecordingWithSpace {
                SettingNotice("Needs the Accessibility permission to see Space in every app. Space is only intercepted while a recording runs; no other keystroke is captured.",
                              advanced: true) {
                    Button("Open macOS settings") { openPrivacyPane("Privacy_Accessibility") }
                        .buttonStyle(.sDanger)
                }
            }
            SettingRow("Dictate and send",
                       hint: "Stops the dictation, inserts it and presses Return. Only works while recording.",
                       advanced: true) {
                TriggerRecorderField(name: .toggleRecordAndSubmit,
                                     mouseButton: $viewModel.submitMouseButtonHotkey,
                                     modifierKey: $viewModel.submitModifierOnlyHotkey,
                                     chord: $viewModel.submitModifierChord,
                                     style: .chips)
            }
            SettingRow("Paste the last dictation",
                       hint: "Inserts your latest dictation again wherever the cursor is.",
                       advanced: true) {
                TriggerRecorderField(name: .pasteLastTranscription,
                                     mouseButton: $viewModel.pasteMouseButtonUnused,
                                     modifierKey: $viewModel.pasteModifierUnused,
                                     allowsMouse: false,
                                     allowsModifier: false,
                                     style: .chips)
            }
            SettingRow("Confirm before cancelling",
                       hint: "For recordings longer than \(Int(IndicatorViewModel.cancelConfirmationThreshold)) seconds.",
                       advanced: true) {
                SSwitch(isOn: Binding(get: { !viewModel.escCancelWithoutConfirmation },
                                      set: { viewModel.escCancelWithoutConfirmation = !$0 }))
            }
        }
    }

    private func refreshModifierTrigger() {
        let prefs = AppPreferences.shared
        let triggers = RecordingTriggerSet.load(from: prefs.recordingTriggers).triggers
            + RecordingTriggerSet.load(from: prefs.holdRecordingTriggers).triggers
        modifierTrigger = triggers.first { trigger in
            switch trigger {
            case .modifier, .chord: return true
            default: return false
            }
        }?.caps.joined(separator: " ")
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Microphone & language

    private var microphoneGroup: some View {
        SettingsGroup("Microphone & language") {
            SettingRow("Microphone", hint: microphoneHint) {
                SMenu(Text(verbatim: Self.middleTruncated(microphoneLabel))) {
                    Picker("", selection: microphoneSelection) {
                        Text("System Default").tag(MicrophoneService.systemDefaultID)
                        Divider()
                        ForEach(micService.availableMicrophones, id: \.id) { device in
                            Text(verbatim: device.name).tag(device.id)
                        }
                        // The pinned device stays listed while unplugged, or the selection
                        // would match nothing and the menu would show no check at all.
                        if let missing = micService.disconnectedSelection {
                            Text("\(missing.name) (not connected)").tag(missing.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            SettingRow("Spoken language", hint: "Automatic follows the detected language or your keyboard.") {
                SMenu(Text(verbatim: languageLabel)) {
                    Picker("", selection: $viewModel.selectedLanguage) {
                        ForEach(viewModel.supportedLanguages, id: \.self) { code in
                            Text(verbatim: LanguageUtil.languageNames[code] ?? code).tag(code)
                        }
                        Divider()
                        Text(verbatim: KeyboardLanguage.displayName).tag(KeyboardLanguage.selectionCode)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                // Rebuilt when the engine's languages change, so the selection never sticks on
                // a value that left the list.
                .id(viewModel.supportedLanguages)
                .onAppear { viewModel.clampLanguageToSupported() }
            }
            SettingRow("Translate to English", hint: translateHint, badge: ("Whisper", .engine)) {
                SSwitch(isOn: $viewModel.translateToEnglish)
                    .disabled(!viewModel.canTranslate)
                    .opacity(viewModel.canTranslate ? 1 : 0.5)
            }
            if viewModel.canTranslate && viewModel.translateToEnglish && viewModel.selectedEngine == "remote" {
                SettingNotice("We can't confirm this server's model supports translation.")
            }
        }
    }

    private var microphoneSelection: Binding<String> {
        Binding(
            get: {
                micService.followsSystemDefault
                    ? MicrophoneService.systemDefaultID
                    : (micService.selectedMicrophone?.id ?? MicrophoneService.systemDefaultID)
            },
            set: { newID in
                if newID == MicrophoneService.systemDefaultID {
                    micService.resetToDefault()
                } else if let device = micService.availableMicrophones.first(where: { $0.id == newID }) {
                    micService.selectMicrophone(device)
                }
            })
    }

    private var microphoneLabel: String {
        if micService.followsSystemDefault { return String(localized: "System Default") }
        if let missing = micService.disconnectedSelection {
            return String(localized: "\(missing.name) (not connected)")
        }
        return micService.selectedMicrophone?.name ?? String(localized: "System Default")
    }

    private var microphoneHint: LocalizedStringKey {
        if micService.followsSystemDefault {
            if let current = micService.currentMicrophone {
                return "Follows the system input, now \(current.name). Switch headsets and it follows."
            }
            return "Follows the system input. Switch headsets and it follows."
        }
        if micService.disconnectedSelection != nil {
            guard let fallback = micService.currentMicrophone else { return "Not connected." }
            return "Not connected, so recording uses \(fallback.name) until it is back."
        }
        return "Also switchable from the menu bar."
    }

    private var languageLabel: String {
        if viewModel.selectedLanguage == KeyboardLanguage.selectionCode { return KeyboardLanguage.displayName }
        return LanguageUtil.languageNames[viewModel.selectedLanguage] ?? viewModel.selectedLanguage
    }

    private var translateHint: LocalizedStringKey {
        guard viewModel.canTranslate else {
            return viewModel.selectedEngine == "whisper"
                ? "Turbo models don't translate, whatever their documentation says. Pick a non-turbo Whisper model to translate."
                : "Only Whisper and servers translate. The current engine ignores this."
        }
        return "The inserted text is translated into English."
    }

    /// Device names have no length limit, and a menu sized to its label would push the row
    /// wider than the pane.
    static func middleTruncated(_ text: String, limit: Int = 30) -> String {
        guard text.count > limit else { return text }
        let half = (limit - 1) / 2
        return "\(text.prefix(half))…\(text.suffix(half))"
    }

    // MARK: - While dictating

    private var isParakeet: Bool { viewModel.selectedEngine == "fluidaudio" }

    private var whileDictatingGroup: some View {
        SettingsGroup("While dictating") {
            SettingRow("Sound at start and end", hint: "Also plays when a recording is locked hands-free.") {
                SSwitch(isOn: $viewModel.playSoundOnRecordStart)
            }
            SettingRow("Live text",
                       hint: isParakeet ? "Words appear while you speak." : "Only Parakeet shows words while you speak.",
                       badge: ("Parakeet", .engine)) {
                SSwitch(isOn: $viewModel.liveTranscriptionEnabled)
                    .disabled(!isParakeet)
                    .opacity(isParakeet ? 1 : 0.5)
            }
            SettingRow("Type directly into the app",
                       hint: "Inserts confirmed words at the cursor while you dictate. Dictionary and style apply at the end.",
                       advanced: true, soon: true) {
                SSwitch(isOn: .constant(false))
            }
            SettingRow("Pause music", hint: "Resumes what was actually playing when you stop.") {
                SSwitch(isOn: $viewModel.pauseMediaOnRecord)
            }
            SettingRow("Lower the Mac's volume", hint: "Turns the system volume down while you dictate.") {
                SSwitch(isOn: $viewModel.reduceVolumeOnRecord)
            }
            if viewModel.reduceVolumeOnRecord {
                SettingRow("Volume while dictating", indented: true) {
                    SSlider(value: $viewModel.reduceVolumeLevel, range: 0...0.5,
                            valueLabel: "\(Int(viewModel.reduceVolumeLevel * 100)) %")
                }
            }
        }
    }

    // MARK: - Voice commands

    /// The stop phrase is heard on the live caption, so it only works while live text runs.
    private var stopPhraseAvailable: Bool { viewModel.liveTranscriptionEnabled && isParakeet }
    private var stopPhraseSet: Bool { !viewModel.stopPhrase.trimmingCharacters(in: .whitespaces).isEmpty }

    private var voiceCommandsGroup: some View {
        SettingsGroup("Voice commands", advanced: true) {
            SettingRow("Stop phrase",
                       hint: stopPhraseAvailable
                       ? "Saying it as your last words ends the dictation, and it is left out of the text. Empty = off."
                       : "Turn on Live text (Parakeet) to use it.",
                       advanced: true) {
                STextField("over and out", text: $viewModel.stopPhrase, width: 180)
                    .disabled(!stopPhraseAvailable)
                    .opacity(stopPhraseAvailable ? 1 : 0.5)
            }
            if stopPhraseAvailable && stopPhraseSet {
                SettingRow("Silence before stopping",
                           hint: "How long you stay quiet after the phrase before the dictation ends. Longer is safer if you use it in normal speech.",
                           advanced: true, indented: true) {
                    SSlider(value: $viewModel.stopPhraseSilenceMs,
                            range: Double(AppPreferences.stopPhraseSilenceRange.lowerBound)...Double(AppPreferences.stopPhraseSilenceRange.upperBound),
                            step: 100,
                            valueLabel: "\((viewModel.stopPhraseSilenceMs / 1000).formatted(.number.precision(.fractionLength(1)))) s")
                }
            }
            SettingRow("Press Return after",
                       hint: "Sends a message or a command once the stop phrase ends the dictation.",
                       advanced: true) {
                SSwitch(isOn: $viewModel.stopPhraseSubmits)
                    .disabled(!(stopPhraseAvailable && stopPhraseSet))
                    .opacity(stopPhraseAvailable && stopPhraseSet ? 1 : 0.5)
            }
            SettingRow("Open and switch apps by voice",
                       hint: "“Whisper, open Slack.” English only for now.",
                       advanced: true, soon: true) {
                SSwitch(isOn: .constant(false))
            }
        }
    }
}
