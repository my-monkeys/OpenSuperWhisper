import Foundation
import KeyboardShortcuts
import OpenSuperWhisperCore

final class AppPreferences {
    static let shared = AppPreferences()
    private init() {
        runMigrations()
    }

    /// Brings preferences written by older builds up to date, in this order. Runs once, from
    /// `init`, the first time anything touches `shared`. Internal only so a test can replay it
    /// on a store seeded with legacy keys: each step checks the state it migrates from first.
    /// App code must not call it: a second run is not a no-op, it sets the
    /// "onboardingTriggerHealed" flag and can rewrite `recordingTriggers`.
    func runMigrations() {
        migrateOldPreferences()
        seedAppContextPresetsIfNeeded()
        migrateGroqToRemote()
        migrateAIProviderToBackend()
        migrateEndChime()
        migrateIndicatorLayout()
        migrateRecordingTriggers()
        resolveTriggerConflicts()
    }

    /// A key bound both as a recording trigger and as stop-and-submit can only do one of them:
    /// the router checks submit first, so the trigger silently stops starting anything. Installs
    /// that reached that state before the editor prevented it get the submit binding cleared,
    /// since the trigger list is the one the user sees as a list. (#48)
    private func resolveTriggerConflicts() {
        var set = RecordingTriggerSet.load(from: recordingTriggers)
        RecordingTriggerSet.load(from: holdRecordingTriggers).triggers.forEach { set.add($0) }
        let clash = set.conflicts(
            modifier: ModifierKey(rawValue: submitModifierOnlyHotkey) ?? .none,
            mouse: MouseButton(rawValue: submitMouseButtonHotkey) ?? .none)
        if clash.modifier { submitModifierOnlyHotkey = ModifierKey.none.rawValue }
        if clash.mouse { submitMouseButtonHotkey = MouseButton.none.rawValue }
    }

    /// Clears the stop-and-submit binding when `trigger` is that same key, button or chord: a key
    /// joining the trigger lists takes it from submit, the newest assignment winning, for the
    /// same reason as above. The trigger editor in Settings and onboarding's shortcut step both
    /// call it.
    func releaseSubmitBinding(claimedBy trigger: RecordingTrigger) {
        switch trigger {
        case .modifier(let key):
            if submitModifierOnlyHotkey == key.rawValue {
                submitModifierOnlyHotkey = ModifierKey.none.rawValue
            }
        case .mouse(let button):
            if submitMouseButtonHotkey == button.rawValue {
                submitMouseButtonHotkey = MouseButton.none.rawValue
            }
        case .chord(let chord):
            if submitModifierChord == chord.storageValue {
                submitModifierChord = ""
            }
        case .keyCombo, .none:
            break
        }
    }

    /// Carries the three single-slot trigger preferences into the list. Idempotent: only runs
    /// while the new key is unset. The old keys stay readable so a downgrade still finds them.
    private func migrateRecordingTriggers() {
        guard recordingTriggers.isEmpty else {
            healOnboardingTrigger()
            return
        }
        // KeyboardShortcuts only reads UserDefaults.standard, which in the test host is the user's
        // real domain: every test process would start with their binding. Tests get what a fresh
        // install gets.
        let legacyShortcut = DefaultsStore.isRunningTests
            ? KeyboardShortcuts.Name.toggleRecord.defaultShortcut
            : KeyboardShortcuts.getShortcut(for: .toggleRecord)
        recordingTriggers = RecordingTriggerSet.migrated(
            mouseRaw: mouseButtonHotkey,
            modifierRaw: modifierOnlyHotkey,
            shortcut: legacyShortcut).json
    }

    /// Onboarding's Right ⌥ choice is the list's job now. It used to land only in the old
    /// single-slot key, which the migration above had already read on first launch, so a
    /// fresh install kept a trigger list with no Right ⌥ and Settings showed the key as
    /// unbound. Adds or removes it in the regular list, never touching the hold-only one.
    func setRightOptionTrigger(_ enabled: Bool) {
        var set = RecordingTriggerSet.load(from: recordingTriggers)
        let trigger = RecordingTrigger.modifier(.rightOption)
        if enabled {
            guard !RecordingTriggerSet.load(from: holdRecordingTriggers).triggers.contains(trigger)
            else { return }
            set.add(trigger)
        } else {
            set.remove(trigger)
        }
        recordingTriggers = set.json
    }

    /// One-time repair for installs onboarded with that bug: the old key still says Right ⌥
    /// while neither list has it. Once only, so removing it in Settings afterwards sticks.
    private func healOnboardingTrigger() {
        let flag = "onboardingTriggerHealed"
        guard !DefaultsStore.current.bool(forKey: flag) else { return }
        DefaultsStore.current.set(true, forKey: flag)
        guard modifierOnlyHotkey == ModifierKey.rightOption.rawValue else { return }
        setRightOptionTrigger(true)
    }

    /// Carry the old independent indicator switches into one ordered layout, so an existing
    /// install keeps the bubble it had. Idempotent: only runs while the new key is unset.
    private func migrateIndicatorLayout() {
        guard indicatorLayout.isEmpty else { return }
        indicatorLayout = IndicatorLayout.migrated(
            meterMode: indicatorMeterMode,
            showStop: showStopButtonOnIndicator,
            showCancel: showCancelButtonOnIndicator).json
    }

    private func migrateOldPreferences() {
        if let oldPath = DefaultsStore.current.string(forKey: "selectedModelPath"),
           DefaultsStore.current.string(forKey: "selectedWhisperModelPath") == nil {
            DefaultsStore.current.set(oldPath, forKey: "selectedWhisperModelPath")
        }
    }

    /// The standalone Groq engine was folded into the generic remote (OpenAI-compatible)
    /// engine: Groq is now just a preset that points the remote engine at Groq's API. Migrate
    /// existing Groq users once so their engine keeps working with no re-entry — seed the remote
    /// config from their stored Groq URL/model/key and flip `selectedEngine` from "groq" to
    /// "remote". Idempotent: only runs while `selectedEngine` is still "groq".
    private func migrateGroqToRemote() {
        guard selectedEngine == "groq" else { return }
        if remoteServerURL.isEmpty {
            remoteServerURL = "https://api.groq.com/openai/v1"
        }
        if remoteServerModel.isEmpty {
            remoteServerModel = groqModel
        }
        if (remoteServerAPIKey ?? "").isEmpty, let key = groqAPIKey, !key.isEmpty {
            remoteServerAPIKey = key
        }
        selectedEngine = "remote"
    }

    /// The cleanup-backend key was renamed `aiProvider` → `aiBackend` when the built-in llama.cpp
    /// backend added a third value ("builtin"). Carry the stored choice over once, so someone who
    /// had picked "remote" isn't silently dropped back onto the "ollama" default. Idempotent: it
    /// only runs while the new key is unset, and the old key is never read again afterwards.
    private func migrateAIProviderToBackend() {
        let defaults = DefaultsStore.current
        guard defaults.object(forKey: "aiBackend") == nil,
              let old = defaults.string(forKey: "aiProvider"),
              !old.isEmpty
        else { return }
        aiBackend = old
    }

    /// The end chime used to share the start chime's switch. Someone who had it on keeps both
    /// chimes; it only runs while the end chime's own key is unset.
    private func migrateEndChime() {
        let defaults = DefaultsStore.current
        guard defaults.object(forKey: "playSoundOnRecordStop") == nil,
              defaults.object(forKey: "playSoundOnRecordStart") != nil
        else { return }
        playSoundOnRecordStop = playSoundOnRecordStart
    }

    // Engine settings
    @UserDefault(key: "selectedEngine", defaultValue: "whisper")
    var selectedEngine: String

    /// Legacy Groq model selection. Groq is now a preset of the remote engine; this key is read
    /// only by `migrateGroqToRemote()` to seed the remote model for existing users.
    @UserDefault(key: "groqModel", defaultValue: "whisper-large-v3-turbo")
    var groqModel: String

    /// Legacy Groq API key (Keychain). Read only by `migrateGroqToRemote()` to seed
    /// `remoteServerAPIKey` for existing Groq users.
    var groqAPIKey: String? {
        get { Keychain.read("groqAPIKey") }
        set { Keychain.set(newValue, for: "groqAPIKey") }
    }

    // MARK: - Remote (OpenAI-compatible) server engine
    // Used when selectedEngine == "remote". The remote engine talks to any
    // OpenAI-compatible /v1/audio endpoint (Groq, speaches, LiteLLM, a local
    // Ollama-style server, …). The API key is optional — leave it empty for
    // no-auth servers.

    @UserDefault(key: "remoteServerURL", defaultValue: "")
    var remoteServerURL: String

    @UserDefault(key: "remoteServerModel", defaultValue: "")
    var remoteServerModel: String

    /// Remote server API key — Keychain-backed (a secret), not UserDefaults.
    /// Optional: nil/empty means send no Authorization header (no-auth servers).
    var remoteServerAPIKey: String? {
        get { Keychain.read("remoteServerAPIKey") }
        set { Keychain.set(newValue, for: "remoteServerAPIKey") }
    }

    // Request timeout for the remote engine. Enabled by default at URLSession's
    // 60s default; disable (or raise) for slow server-side pipelines that run
    // well past a minute.
    @UserDefault(key: "remoteServerTimeoutEnabled", defaultValue: true)
    var remoteServerTimeoutEnabled: Bool

    @UserDefault(key: "remoteServerTimeoutSeconds", defaultValue: 60.0)
    var remoteServerTimeoutSeconds: Double

    // Last model ids fetched from the remote server's /v1/models, so the menu-bar
    // model picker can list them without a live network call when it opens.
    @UserDefault(key: "cachedRemoteModels", defaultValue: [String]())
    var cachedRemoteModels: [String]

    // MARK: - Context-aware model selection (per-app / per-site rules)

    // Per-app default model rules (bundle id -> model, or "bundleID|host" -> model),
    // JSON-encoded. Managed by AppContextModelRules; empty until the user binds a model.
    @UserDefault(key: "appModelRules", defaultValue: Data())
    var appModelRulesData: Data

    // Context-aware model selection mode: "ask" (auto-switch + prompt), "auto"
    // (auto-switch, no prompt), or "off". Stored raw; use contextAwareModelMode.
    @UserDefault(key: "contextAwareModelMode", defaultValue: "ask")
    var contextAwareModelModeRaw: String

    var contextAwareModelMode: ContextAwareModelMode {
        get { ContextAwareModelMode(rawValue: contextAwareModelModeRaw) ?? .ask }
        set { contextAwareModelModeRaw = newValue.rawValue }
    }

    // User-defined remote presets (name + URL + model + timeout), JSON-encoded.
    // Each preset's API key lives in the Keychain under "remotePreset.<uuid>",
    // never in UserDefaults. Managed by RemoteUserPresets.
    @UserDefault(key: "remoteUserPresets", defaultValue: Data())
    var remoteUserPresetsData: Data

    // Local fallback for the remote engine: when the server is unreachable, transcribe
    // with a downloaded on-device model instead. Off by default; the chosen model is a
    // DictationModelOption stored as JSON (empty until the user picks one).
    @UserDefault(key: "remoteFallbackEnabled", defaultValue: false)
    var remoteFallbackEnabled: Bool

    @UserDefault(key: "remoteFallbackModelData", defaultValue: Data())
    var remoteFallbackModelData: Data

    var remoteFallbackModel: DictationModelOption? {
        get {
            guard !remoteFallbackModelData.isEmpty else { return nil }
            return try? JSONDecoder().decode(DictationModelOption.self, from: remoteFallbackModelData)
        }
        set {
            remoteFallbackModelData = newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        }
    }

    // Model settings
    var selectedModelPath: String? {
        get {
            if selectedEngine == "whisper" {
                return selectedWhisperModelPath
            }
            return nil
        }
        set {
            if selectedEngine == "whisper" {
                selectedWhisperModelPath = newValue
            }
        }
    }
    
    @OptionalUserDefault(key: "selectedWhisperModelPath")
    var selectedWhisperModelPath: String?
    
    @UserDefault(key: "fluidAudioModelVersion", defaultValue: "v3")
    var fluidAudioModelVersion: String
    
    @UserDefault(key: "whisperLanguage", defaultValue: "en")
    var whisperLanguage: String
    
    // Transcription settings
    @UserDefault(key: "translateToEnglish", defaultValue: false)
    var translateToEnglish: Bool
    
    @UserDefault(key: "suppressBlankAudio", defaultValue: true)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    var noSpeechThreshold: Double
    
    @UserDefault(key: "initialPrompt", defaultValue: "")
    var initialPrompt: String

    // Custom dictionary settings
    @UserDefault(key: "customDictionaryEnabled", defaultValue: false)
    var customDictionaryEnabled: Bool

    /// Whether the dictionary's terms also bias *recognition* (Whisper prompt boost / Parakeet
    /// vocabulary boosting), on top of the always-on text replacement. Opt-in and default OFF:
    /// boosting is fuzzy and helps rare, distinctive jargon ("Kubernetes") but over-corrects
    /// short, common terms (it rewrites vaguely-similar spans). Replacement alone is exact and
    /// safe, so the common case (fixing the spelling/casing of correctly-heard words) needs no
    /// boosting. See `CustomDictionary.boostTerms`.
    @UserDefault(key: "customDictionaryBoostEnabled", defaultValue: false)
    var customDictionaryBoostEnabled: Bool

    /// Read what is already written in the field being dictated into, and let the transcriber
    /// expect those words.
    ///
    /// Off by default and deliberately so. Everything else the app reads about the target is a
    /// label: the app name, a window title, a URL host. This reads the writing itself, which is
    /// a different kind of access and has to be asked for rather than assumed. It never leaves
    /// the Mac: only the on-device engines receive it, and it is held in memory for the length
    /// of one dictation.
    @UserDefault(key: "useSurroundingTextAsContext", defaultValue: false)
    var useSurroundingTextAsContext: Bool

    /// Keep reading the field a dictation went into for a short while, and offer the words the
    /// user corrects there for the dictionary (#169).
    ///
    /// Off by default for the reason `matchTextAroundCaret` is, and more so: this reads the
    /// writing itself, for up to a minute after each dictation rather than once before it. What
    /// it reads stays in memory and is dropped once the watch ends; only a word the user is
    /// offered is kept, in `dictionarySuggestionsData`, until they answer.
    @UserDefault(key: "suggestDictionaryWords", defaultValue: false)
    var suggestDictionaryWords: Bool

    /// Words offered and not answered yet, as JSON, for the dictionary's Suggested list.
    @OptionalUserDefault(key: "dictionarySuggestionsData")
    var dictionarySuggestionsData: Data?

    /// Words the user turned down or deleted from the dictionary, never offered again. Stored as
    /// keyed digests, not words (`DictionarySuggestions.digest`): an address someone refused to
    /// keep should not stay on disk as text.
    @UserDefault(key: "dictionaryRefusedWords", defaultValue: [String]())
    var dictionaryRefusedWords: [String]

    @OptionalUserDefault(key: "customDictionaryData")
    private var customDictionaryData: Data?

    var customDictionaryEntries: [CustomDictionaryEntry] {
        get {
            guard let data = customDictionaryData,
                  let entries = try? JSONDecoder().decode([CustomDictionaryEntry].self, from: data) else {
                return []
            }
            return entries
        }
        set {
            customDictionaryData = try? JSONEncoder().encode(newValue)
        }
    }

    /// On by default, unlike the dictionary: a snippet does nothing until the user writes one,
    /// and one that has been written is meant to work straight away (#167).
    @UserDefault(key: "snippetsEnabled", defaultValue: true)
    var snippetsEnabled: Bool

    /// Whether the snippet triggers also bias recognition. Off by default for the reason the
    /// dictionary's boost is: triggers tend to be short, common phrases ("my email"), which
    /// boosting over-corrects, and on Parakeet any boost moves the file pass to the slower
    /// sliding-window decoder. See `RecognitionBoost`.
    @UserDefault(key: "snippetsBoostEnabled", defaultValue: false)
    var snippetsBoostEnabled: Bool

    @OptionalUserDefault(key: "snippetsData")
    private var snippetsData: Data?

    var snippets: [Snippet] {
        get {
            guard let data = snippetsData,
                  let snippets = try? JSONDecoder().decode([Snippet].self, from: data) else {
                return []
            }
            return snippets
        }
        set {
            snippetsData = try? JSONEncoder().encode(newValue)
        }
    }

    /// The triggers a dictation boosts, when snippets and their boost are on. Set on the clip by
    /// the dictation paths only (see `RecognitionBoost`).
    var dictationSnippetTriggers: [String] {
        snippetsEnabled && snippetsBoostEnabled ? SnippetExpander.boostTerms(snippets) : []
    }

    /// The dictation with its snippet triggers expanded, when snippets are on. Run on the text
    /// the cleanup model returns, never before it (see `SnippetExpander`). The dictionary rules
    /// are passed along because they ran first and may have rewritten part of a trigger.
    func expandSnippets(_ text: String) -> String {
        guard snippetsEnabled else { return text }
        let snippets = self.snippets
        guard !snippets.isEmpty else { return text }
        return SnippetExpander.expand(text, snippets: snippets,
                                      dictionary: customDictionaryEnabled ? customDictionaryEntries : [])
    }
    
    @UserDefault(key: "useBeamSearch", defaultValue: false)
    var useBeamSearch: Bool

    // Opt-in on-bubble recording controls (default off; additive to the baseline).
    @UserDefault(key: "showStopButtonOnIndicator", defaultValue: false)
    var showStopButtonOnIndicator: Bool

    @UserDefault(key: "showCancelButtonOnIndicator", defaultValue: false)
    var showCancelButtonOnIndicator: Bool
    
    @UserDefault(key: "beamSize", defaultValue: 5)
    var beamSize: Int
    
    @UserDefault(key: "debugMode", defaultValue: false)
    var debugMode: Bool
    
    /// Chime at the start of a take, and when it is locked hands-free.
    @UserDefault(key: "playSoundOnRecordStart", defaultValue: false)
    var playSoundOnRecordStart: Bool

    /// Chime when a take stops and goes on to be transcribed. See `migrateEndChime()`.
    @UserDefault(key: "playSoundOnRecordStop", defaultValue: false)
    var playSoundOnRecordStop: Bool

    /// Launch into the menu bar without showing the main window (opt-in).
    @UserDefault(key: "startHidden", defaultValue: false)
    var startHidden: Bool

    /// Show the transcription live (in the indicator) while recording. Parakeet only; opt-in.
    @UserDefault(key: "liveTranscriptionEnabled", defaultValue: false)
    var liveTranscriptionEnabled: Bool

    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool

    /// The one-time request for feedback on the rebuilt interface is behind us (#206): the card
    /// was shown, or feedback was sent from anywhere. Set the moment the card appears, so a quit
    /// or a crash while it is up does not bring it back. Nothing sets it back to false.
    @UserDefault(key: "feedbackPromptDone", defaultValue: false)
    var feedbackPromptDone: Bool

    /// Launches that started with onboarding already done, counted only up to
    /// `FeedbackPrompt.minimumLaunches`: all the request needs to know is whether it is reached.
    @UserDefault(key: "feedbackPromptLaunches", defaultValue: 0)
    var feedbackPromptLaunches: Int

    @UserDefault(key: "useAsianAutocorrect", defaultValue: true)
    var useAsianAutocorrect: Bool
    
    @OptionalUserDefault(key: "selectedMicrophoneData")
    var selectedMicrophoneData: Data?
    
    @UserDefault(key: "modifierOnlyHotkey", defaultValue: "none")
    var modifierOnlyHotkey: String

    @UserDefault(key: "mouseButtonHotkey", defaultValue: "none")
    var mouseButtonHotkey: String

    // The trigger modes are mutually exclusive, so switching modes clears the
    // other two prefs. These remember each mode's last choice so switching
    // back restores it instead of the hardcoded default.
    @UserDefault(key: "lastModifierOnlyHotkey", defaultValue: "leftCommand")
    var lastModifierOnlyHotkey: String

    @UserDefault(key: "lastMouseButtonHotkey", defaultValue: "middle")
    var lastMouseButtonHotkey: String

    /// A second mouse button that dictates and then presses Return, for apps where dictation
    /// is followed by submitting (chat prompts, search fields). Same outcome as the spoken
    /// "press enter" command, without saying it. "none" disables it. (#50)
    @UserDefault(key: "submitMouseButtonHotkey", defaultValue: "none")
    var submitMouseButtonHotkey: String

    /// Recording triggers as JSON (`RecordingTriggerSet`): any number of key combinations,
    /// single modifiers and mouse buttons, all live at once. Empty until
    /// `migrateRecordingTriggers()` builds it from the three single-slot preferences. (#48)
    @UserDefault(key: "recordingTriggers", defaultValue: "")
    var recordingTriggers: String

    /// Triggers that always record only while held, whatever `holdToRecord` says: press to
    /// start, release to stop. Same JSON shape as `recordingTriggers`, and no key is in both.
    @UserDefault(key: "holdRecordingTriggers", defaultValue: "")
    var holdRecordingTriggers: String

    /// Single modifier for the same dictate-and-submit action. (#50)
    @UserDefault(key: "submitModifierOnlyHotkey", defaultValue: "none")
    var submitModifierOnlyHotkey: String

    /// Stop-and-submit as a chord of modifiers (⌘⌥ alone), stored as `ModifierChord`'s flags.
    /// Empty = none. Kept apart from the single-modifier key so older builds still read that.
    @UserDefault(key: "submitModifierChord", defaultValue: "")
    var submitModifierChord: String

    // When false (default), pressing Esc to cancel a recording longer than
    // ~10s first asks for confirmation (press Esc again) instead of discarding
    // it outright — a safety net against an accidental Esc losing a long dictation.
    @UserDefault(key: "escCancelWithoutConfirmation", defaultValue: false)
    var escCancelWithoutConfirmation: Bool

    // When true, the Whisper model is freed from RAM (~1GB) between dictations and
    // reloaded on demand for each one — trades a bit of start latency for memory.
    // Off by default (the model stays resident for the fastest first word).
    @UserDefault(key: "unloadWhisperModelWhenIdle", defaultValue: false)
    var unloadWhisperModelWhenIdle: Bool
    
    @UserDefault(key: "holdToRecord", defaultValue: true)
    var holdToRecord: Bool

    /// Space (or a double-tap of the trigger) pins an in-progress recording so it survives letting
    /// go of the trigger key. Opt-in: it needs Accessibility and installs a keyboard event tap, so
    /// nobody gets that footprint without asking for it.
    @UserDefault(key: "latchRecordingWithSpace", defaultValue: false)
    var latchRecordingWithSpace: Bool

    @UserDefault(key: "addSpaceAfterSentence", defaultValue: true)
    var addSpaceAfterSentence: Bool

    /// Run a user shell command after each successful transcription. Opt-in (power user).
    @UserDefault(key: "postRecordHookEnabled", defaultValue: false)
    var postRecordHookEnabled: Bool

    /// The command run via `/bin/sh -c` after transcription. Receives OSW_* env vars + JSON on stdin.
    @UserDefault(key: "postRecordHookCommand", defaultValue: "")
    var postRecordHookCommand: String

    /// Where the recording indicator appears: "cursor" (default), "top", "center", "bottom".
    /// Multiplier applied on top of the system text size. 1.0 means "exactly what macOS asks
    /// for"; the control exists because following the system alone leaves no room for wanting
    /// this one app bigger than the rest. (#80)
    @UserDefault(key: "textScale", defaultValue: TextScale.default)
    var textScale: Double

    @UserDefault(key: "indicatorPosition", defaultValue: "cursor")
    var indicatorPosition: String

    /// UI theme during the Liquid Glass transition: "system", "legacy", or "liquidGlass".
    /// Read through `ThemeController` / the `UITheme` enum, never compared as a raw string in views.
    @UserDefault(key: "uiTheme", defaultValue: "system")
    var uiTheme: String

    /// Appearance of the app's windows: "system", "light" or "dark". Read through
    /// `AppearanceController`, which applies it to `NSApp`.
    @UserDefault(key: "appAppearance", defaultValue: "system")
    var appAppearance: String

    /// Settings rubrics whose Advanced switch is on, by `SettingsRubric` raw value. Remembered so
    /// someone who tunes a rubric often does not have to reveal its options on every visit.
    @UserDefault(key: "settingsAdvancedRubrics", defaultValue: [String]())
    var settingsAdvancedRubrics: [String]

    /// Size factor of the Liquid Glass recording bubble (1 = Spotlight-sized). Read through
    /// `ThemeController`.
    @UserDefault(key: "glassBubbleSize", defaultValue: 0.8)
    var glassBubbleSize: Double

    /// Where the bubble was last dragged to, as "x,y": the middle of its bottom edge in screen
    /// coordinates.
    ///
    /// The same pair of anchors the preset positions produce, so a bubble you dropped somewhere
    /// grows upward from that spot exactly as the presets do rather than drifting as its contents
    /// change. nil until it has been dragged once.
    @OptionalUserDefault(key: "indicatorCustomAnchor")
    private var indicatorCustomAnchorRaw: String?

    var indicatorCustomAnchor: CGPoint? {
        get {
            guard let raw = indicatorCustomAnchorRaw else { return nil }
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
        set {
            guard let newValue else { indicatorCustomAnchorRaw = nil; return }
            indicatorCustomAnchorRaw = "\(newValue.x),\(newValue.y)"
        }
    }

    /// The bubble's contents as JSON (`IndicatorLayout`): which elements it shows and in
    /// what order. Empty until `migrateIndicatorLayout()` builds one from the old
    /// meter-mode / show-stop / show-cancel preferences.
    @UserDefault(key: "indicatorLayout", defaultValue: "")
    var indicatorLayout: String

    /// Superseded by `indicatorLayout`; still read once by the migration.
    @UserDefault(key: "indicatorMeterMode", defaultValue: "replacesDot")
    var indicatorMeterMode: String

    /// Strip filler words (um, uh, …) from the transcription before saving/inserting. Opt-in.
    @UserDefault(key: "removeFillerWords", defaultValue: false)
    var removeFillerWords: Bool

    /// User-editable, case-insensitive regex matching the filler words to remove.
    @UserDefault(key: "fillerWordsPattern", defaultValue: "\\b(um|uh|uh huh|er|ah|hmm|mm)\\b,?\\s*")
    var fillerWordsPattern: String

    /// Removes the configured filler words (when enabled) and tidies leftover whitespace.
    /// The matching itself is in `stripFillerWords`.
    func cleanTranscription(_ text: String) -> String {
        guard removeFillerWords, !fillerWordsPattern.isEmpty else { return text }
        return Self.stripFillerWords(text, pattern: fillerWordsPattern)
    }

    /// Pure removal behind `cleanTranscription` (unit-tested directly). An invalid regex
    /// removes nothing.
    ///
    /// It runs after the custom dictionary, so the text can already hold the line breaks a
    /// "new paragraph" rule wrote. Those must come out exactly as they would with the option
    /// off (#179): each match gives back the line breaks it consumed, since the default
    /// pattern ends in `\s*` and a user's pattern may take whitespace from either side, and the
    /// tidy-up only ever touches spaces and tabs.
    static func stripFillerWords(_ text: String, pattern: String) -> String {
        removingKeepingLineBreaks(pattern, from: text)
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            // A filler removed at the edge of a line leaves its space behind there.
            .replacingOccurrences(of: "[ \\t]+(?=[\\r\\n])|(?<=[\\r\\n]) +", with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    private static func removingKeepingLineBreaks(_ pattern: String, from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            result += text[range].filter(\.isNewline)
            cursor = range.upperBound
        }
        return result + text[cursor...]
    }

    // AI post-processing (clean up the transcription with a local LLM). Opt-in.
    @UserDefault(key: "aiPostProcessingEnabled", defaultValue: false)
    var aiPostProcessingEnabled: Bool

    /// Which LLM backend serves cleanup/formatting: "ollama" (external server), "builtin"
    /// (embedded llama.cpp), "remote" (any OpenAI-compatible /v1/chat/completions server —
    /// Groq, OpenAI, LiteLLM…), or "apple" (Apple's on-device model, macOS 26). Renamed from the
    /// older `aiProvider` key, which `migrateAIProviderToBackend()` carries over for existing users.
    ///
    /// Until the user picks one, nothing is stored and the getter resolves the default on each
    /// read (`LLMPostProcessor.effectiveBackend`): Apple Intelligence when this Mac can run it for
    /// the dictation language, Ollama otherwise.
    var aiBackend: String {
        get {
            LLMPostProcessor.effectiveBackend(stored: storedAIBackend,
                                              appleIntelligence: appleIntelligenceAvailability)
        }
        set { storedAIBackend = newValue }
    }

    @OptionalUserDefault(key: "aiBackend")
    private var storedAIBackend: String?

    /// Apple Intelligence for the language dictations are cleaned up in.
    var appleIntelligenceAvailability: AppleIntelligenceAvailability {
        AppleIntelligence.availability(language: dictationLanguage)
    }

    /// The language a dictation made now would come out in, as `cleanupLanguage` resolves it.
    var dictationLanguage: String? {
        Self.cleanupLanguage(
            stored: whisperLanguage, translateToEnglish: translateToEnglish,
            keyboardLanguage: { [self] in
                KeyboardLanguage.current(engine: selectedEngine, fluidAudioModelVersion: fluidAudioModelVersion)
            })
    }

    /// The language a dictation reaches the cleanup in: English once Whisper has translated it,
    /// otherwise the transcription language. "From keyboard layout" is stored as a selection
    /// code, not a language, so it is resolved to the layout's language, and to nil (unknown,
    /// like auto-detect) when the layout declares none the engine supports.
    static func cleanupLanguage(stored: String, translateToEnglish: Bool,
                                keyboardLanguage: () -> String?) -> String? {
        if translateToEnglish { return "en" }
        guard stored == KeyboardLanguage.selectionCode else { return stored }
        return keyboardLanguage()
    }

    @UserDefault(key: "aiOllamaEndpoint", defaultValue: "http://localhost:11434")
    var aiOllamaEndpoint: String

    @UserDefault(key: "aiOllamaModel", defaultValue: "llama3.2")
    var aiOllamaModel: String

    // Remote-LLM cleanup: its own server/model/key, independent of the Remote STT
    // engine (so cleanup works even when transcription runs on-device). The Settings
    // pane can prefill these from the Remote engine's config for convenience.
    @UserDefault(key: "aiRemoteEndpoint", defaultValue: "https://api.groq.com/openai/v1")
    var aiRemoteEndpoint: String

    @UserDefault(key: "aiRemoteModel", defaultValue: "llama-3.1-8b-instant")
    var aiRemoteModel: String

    /// Remote-LLM cleanup API key — Keychain-backed (a secret), not UserDefaults.
    /// nil/empty means send no Authorization header (no-auth/local servers).
    var aiRemoteAPIKey: String? {
        get { Keychain.read("aiRemoteAPIKey") }
        set { Keychain.set(newValue, for: "aiRemoteAPIKey") }
    }

    // Which built-in GGUF the local cleanup backend loads. Stored as the file name so an entry
    // that disappears from `LLMModelManager.availableModels` degrades to the default instead of
    // crashing. Unset means the small model everyone already has downloaded.
    @UserDefault(key: "builtInModelFileName", defaultValue: LLMModelManager.defaultModel.fileName)
    var builtInModelFileName: String

    @UserDefault(key: "unloadBuiltInModelWhenIdle", defaultValue: true)
    var unloadBuiltInModelWhenIdle: Bool

    // The complete system prompt for the cleanup pass. The app wraps nothing around it and
    // substitutes nothing in it, so this field is the whole contract — including the guardrail
    // that keeps a weak model transforming rather than answering, and the output language.
    @UserDefault(key: "aiPostProcessingPrompt", defaultValue: LLMPostProcessor.defaultInstruction)
    var aiPostProcessingPrompt: String

    // The closing half, placed after any app-specific rules so it stays the model's last word.
    @UserDefault(key: "aiPostProcessingClosing",
                 defaultValue: LLMPostProcessor.defaultClosingInstruction)
    var aiPostProcessingClosing: String

    // Sent only while "Translate to English" is on. Kept apart from the general instruction
    // because a prompt that mentions translating confuses the model on every dictation that
    // isn't one (#86).
    @UserDefault(key: "aiPostProcessingTranslation",
                 defaultValue: LLMPostProcessor.defaultTranslationInstruction)
    var aiPostProcessingTranslation: String

    // App-aware LLM formatting: per-app instructions, keyed by frontmost bundle identifier, that
    // reshape the transcription via the same local LLM (e.g. "at Rob" -> "@Rob" in Slack). This is
    // independent of `aiPostProcessingEnabled`: either feature can contribute to a single LLM pass.
    @UserDefault(key: "appContextFormattingEnabled", defaultValue: false)
    var appContextFormattingEnabled: Bool

    /// Milliseconds between keystroke chunks while typing. See `TextInserter`.
    ///
    /// A dial rather than a constant because the quantity it has to cover, the target's redraw
    /// cost, is not something we can read in every app: the accessibility read comes back empty
    /// in several, including the Electron terminal that produced #85. Handing the number to the
    /// person who hits the bug beats another constant chosen by reasoning, which is how the
    /// first attempt came to scale on the wrong thing.
    @UserDefault(key: "typingPaceMilliseconds", defaultValue: 2)
    var typingPaceMilliseconds: Int

    @OptionalUserDefault(key: "appInsertionRulesData")
    private var appInsertionRulesData: Data?

    /// Per-app overrides of how text is inserted. Empty by default: no rule means the global
    /// paste-or-type setting decides, exactly as before.
    var appInsertionRules: [AppInsertionRule] {
        get {
            guard let data = appInsertionRulesData,
                  let rules = try? JSONDecoder().decode([AppInsertionRule].self, from: data)
            else { return [] }
            return rules
        }
        set {
            appInsertionRulesData = try? JSONEncoder().encode(newValue)
        }
    }

    @OptionalUserDefault(key: "appContextProfilesData")
    private var appContextProfilesData: Data?

    var appContextProfiles: [AppContextProfile] {
        get {
            guard let data = appContextProfilesData,
                  let profiles = try? JSONDecoder().decode([AppContextProfile].self, from: data) else {
                return []
            }
            return profiles
        }
        set {
            appContextProfilesData = try? JSONEncoder().encode(newValue)
        }
    }

    // MARK: - Writing styles (#160)

    /// The style AI cleanup writes in wherever no app rule picks one. Raw by default, which adds
    /// nothing to the prompt and so keeps cleanup exactly as it was before styles.
    @UserDefault(key: "writingStyleID", defaultValue: WritingStyle.rawID)
    var writingStyleID: String

    @OptionalUserDefault(key: "customWritingStylesData")
    private var customWritingStylesData: Data?

    /// The styles the user wrote, after the three built-in ones.
    var customWritingStyles: [WritingStyle] {
        get {
            guard let data = customWritingStylesData,
                  let styles = try? JSONDecoder().decode([WritingStyle].self, from: data) else { return [] }
            return styles
        }
        set { customWritingStylesData = try? JSONEncoder().encode(newValue) }
    }

    /// Bundle identifier, lowercased, to style id: an app that always gets the same voice.
    @UserDefault(key: "appWritingStyles", defaultValue: [String: String]())
    var appWritingStyles: [String: String]

    /// The style for a dictation into `bundleID`: the app's own if it has one, else the default.
    func writingStyle(for bundleID: String?) -> WritingStyle {
        let appStyle = bundleID.flatMap { appWritingStyles[$0.lowercased()] }
        return WritingStyle.resolve(appStyle ?? writingStyleID, custom: customWritingStyles)
    }

    /// Flips true once the bundled presets have been seeded, so a user who deletes them keeps
    /// them deleted (we never re-seed). See `seedAppContextPresetsIfNeeded`.
    @UserDefault(key: "didSeedAppContextPresets", defaultValue: false)
    var didSeedAppContextPresets: Bool

    /// One-time seed of the bundled app-context presets (Slack). Only populates an empty list so
    /// it never clobbers user-authored profiles, and only runs once (the flag persists the choice).
    private func seedAppContextPresetsIfNeeded() {
        guard !didSeedAppContextPresets else { return }
        if appContextProfiles.isEmpty {
            appContextProfiles = AppContextProfile.defaultPresets
        }
        didSeedAppContextPresets = true
    }

    // Clipboard settings
    @UserDefault(key: "autoCopyToClipboard", defaultValue: true)
    var autoCopyToClipboard: Bool

    @UserDefault(key: "autoPasteTranscription", defaultValue: true)
    var autoPasteTranscription: Bool

    /// With "Copy to clipboard" off, how long the dictation stays on the clipboard for the paste
    /// before the previous contents come back. Shorter gives the old item back sooner; too short
    /// and a slow app could paste the old item instead of the dictation.
    @UserDefault(key: "clipboardRestoreDelayMs", defaultValue: 500)
    var clipboardRestoreDelayMs: Int
    static let clipboardRestoreDelayRange = 150...2000

    /// Insert by pasting (⌘V) — the default, because it's universal: it lands in any text field,
    /// including apps that ignore synthetic Unicode typing (Messages, Electron, …). Turn it off to
    /// type the transcription instead (preserves the clipboard, but fails in those apps).
    @UserDefault(key: "pasteInsteadOfTyping", defaultValue: true)
    var pasteInsteadOfTyping: Bool

    /// When auto-paste is on but no editable field is focused, show a brief
    /// "copied — press ⌘V" notice instead of letting the paste silently go nowhere.
    @UserDefault(key: "notifyWhenNoPasteTarget", defaultValue: true)
    var notifyWhenNoPasteTarget: Bool

    /// Put the focus back in the field the dictation started in before inserting, when the user
    /// has clicked elsewhere while it was transcribed (#164). On by default; some people dictate
    /// and then deliberately move to the field the text is meant for.
    @UserDefault(key: "pasteIntoOriginalField", defaultValue: true)
    var pasteIntoOriginalField: Bool

    /// Read the field just before inserting and fit the dictation to it: lowercase in the middle
    /// of a sentence, no final period before the rest of one, a space where words meet (#163).
    ///
    /// Off by default for the reason `useSurroundingTextAsContext` is: this reads the writing
    /// itself, not a label about it, and that has to be asked for. What it reads stays in memory
    /// for the one insertion.
    @UserDefault(key: "matchTextAroundCaret", defaultValue: false)
    var matchTextAroundCaret: Bool

    /// Paste a dictated list as real bullets into the apps known to take rich text (#166).
    ///
    /// Off by default until it has been checked by hand in Notes, Pages and Word. The RTF those
    /// apps read names a font (the writer's Helvetica 12 pt, for the lines around the list too),
    /// and an app that keeps the source formatting on paste would show the dictation in it rather
    /// than in the field's own font, which a plain paste always takes.
    @UserDefault(key: "pasteListsAsRichText", defaultValue: false)
    var pasteListsAsRichText: Bool

    /// Paste a long dictation into Claude Code or Codex in a terminal a few lines at a time, so
    /// it shows in full instead of folding into a placeholder (#165).
    ///
    /// Off by default until it has been checked by hand in both agents and the terminals they
    /// run in: the thresholds were read in their code, not measured, and a piece that arrived
    /// while the prompt was still redrawing the last one could land out of place.
    @UserDefault(key: "pasteAgentPromptsInPieces", defaultValue: false)
    var pasteAgentPromptsInPieces: Bool

    /// When on, a trailing "press enter" in the dictation is removed from the text and a Return
    /// key is pressed after the text is inserted — submitting the message/prompt (Claude Code,
    /// Slack, …). Opt-in: a stray Return can submit a form prematurely. See `stripSubmitCommand`.
    @UserDefault(key: "submitOnVoiceCommand", defaultValue: false)
    var submitOnVoiceCommand: Bool

    /// Detects a trailing "press enter" voice command, gated by `submitOnVoiceCommand`. Returns the
    /// text with the command removed, plus whether it was present. No-op (text unchanged,
    /// `submit: false`) when the preference is off. The matching itself is in `parseSubmitCommand`.
    func stripSubmitCommand(_ text: String) -> (text: String, submit: Bool) {
        guard submitOnVoiceCommand else { return (text, false) }
        return Self.parseSubmitCommand(text)
    }

    /// Pure regex extraction behind `stripSubmitCommand` (unit-tested directly). Strips a trailing
    /// "press enter" — optionally preceded by whitespace/commas and followed by trailing
    /// whitespace/punctuation — anchored to the end of the text.
    ///
    /// Because it only anchors to the end, "press enter" earlier in a sentence ("press enter to
    /// continue reading") is left alone. A phrase that genuinely *ends* in "press enter"
    /// ("tell him to press enter") IS stripped — an accepted ambiguity of an end-of-utterance voice
    /// command. A preceding sentence period ("Send this. Press enter.") is kept (only whitespace/
    /// commas are consumed before the command).
    static func parseSubmitCommand(_ text: String) -> (text: String, submit: Bool) {
        let pattern = "[\\s,]*press[\\s,]+enter[\\s\\p{P}]*$"
        guard let range = text.range(
            of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return (text, false)
        }
        return (String(text[..<range.lowerBound]), true)
    }

    /// Words that end a recording when spoken last, so a take started remotely (a phone Shortcut
    /// sending the trigger over SSH) needs no second press. Empty = off. It is heard on the live
    /// transcript, so it only works where live transcription runs (Parakeet). (#145)
    @UserDefault(key: "stopPhrase", defaultValue: "")
    var stopPhrase: String

    /// Also press Return when the stop phrase ends a take, like the submit shortcut does. (#145)
    @UserDefault(key: "stopPhraseSubmits", defaultValue: false)
    var stopPhraseSubmits: Bool

    /// Milliseconds of silence the microphone needs after the stop phrase before the take
    /// ends. Shorter stops sooner; longer survives a pause right after saying the phrase as
    /// content. (#145)
    @UserDefault(key: "stopPhraseSilenceMs", defaultValue: 1000)
    var stopPhraseSilenceMs: Int
    static let stopPhraseSilenceRange = 300...3000

    /// Which moments bring the panel up. Each off, that hook hands straight back to the terminal.
    @UserDefault(key: "agentAskOnStop", defaultValue: true)
    var agentAskOnStop: Bool
    @UserDefault(key: "agentAskOnPermission", defaultValue: true)
    var agentAskOnPermission: Bool
    @UserDefault(key: "agentAskOnQuestion", defaultValue: true)
    var agentAskOnQuestion: Bool

    /// How long the panel waits for an answer before handing the agent back to its terminal.
    /// Claude Code kills the hook at 600 s, so this stays under it.
    @UserDefault(key: "agentWaitSeconds", defaultValue: 300)
    var agentWaitSeconds: Int
    static let agentWaitChoices = [60, 120, 300, 590]

    /// The agents OpenSuperWhisper answers for, by `AgentKind` raw value. Claude Code only by
    /// default: it is the one the plugin is installed for, and an agent that picked the plugin
    /// up by itself (Codex imports Claude Code's marketplaces) stays in its terminal until the
    /// user turns it on in Settings.
    @UserDefault(key: "agentEnabledKinds", defaultValue: [AgentKind.claudeCode.rawValue])
    var agentEnabledKinds: [String]

    func agentKindEnabled(_ kind: AgentKind) -> Bool {
        agentEnabledKinds.contains(kind.rawValue)
    }

    func setAgentKind(_ kind: AgentKind, enabled: Bool) {
        var kinds = agentEnabledKinds.filter { $0 != kind.rawValue }
        if enabled { kinds.append(kind.rawValue) }
        agentEnabledKinds = kinds
    }

    /// Projects whose agents always use their terminal, by folder path. A subfolder counts.
    @UserDefault(key: "agentDisabledProjects", defaultValue: [String]())
    var agentDisabledProjects: [String]
    /// The folders agents have asked from, newest first, for the Agents pane to list.
    @UserDefault(key: "agentRecentProjects", defaultValue: [String]())
    var agentRecentProjects: [String]
    static let agentRecentProjectLimit = 20

    func rememberAgentProject(_ path: String) {
        guard !path.isEmpty else { return }
        agentRecentProjects = Array(([path] + agentRecentProjects.filter { $0 != path })
            .prefix(Self.agentRecentProjectLimit))
    }

    func agentProjectEnabled(_ path: String) -> Bool {
        Self.agentProjectTurnedOff(path, by: agentDisabledProjects) == nil
    }

    /// The turned-off folder that keeps agents in `path` in their terminal: `path` itself, or
    /// the nearest turned-off folder above it. nil when they use the panel. The hook and the
    /// Agents pane both ask here, so a project's switch cannot read on while it is off (#171).
    static func agentProjectTurnedOff(_ path: String, by disabled: [String]) -> String? {
        disabled.filter { agentFolder($0, covers: path) }.max { $0.count < $1.count }
    }

    /// Whether a switch on `folder` reaches agents started in `path`: the folder itself and
    /// everything below it, but not a sibling that only starts with the same name.
    private static func agentFolder(_ folder: String, covers path: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    func setAgentProject(_ path: String, enabled: Bool) {
        var disabled = agentDisabledProjects.filter { $0 != path }
        if !enabled { disabled.append(path) }
        agentDisabledProjects = disabled
    }

    /// The dictation with a trailing stop phrase removed. The phrase is a command, not content,
    /// so it is dropped whichever way the take ended. `cutAtLast` is for a take the phrase
    /// ended: the recorder runs on a moment after it, so the text is cut at its last
    /// occurrence, dropping whatever was caught after.
    func stripStopPhrase(_ text: String, cutAtLast: Bool = false) -> String {
        Self.parseStopPhrase(text, phrase: stopPhrase, anchoredToEnd: !cutAtLast).text
    }

    /// Pure matching behind `stripStopPhrase` and the live watcher (unit-tested directly). Same
    /// shape as `parseSubmitCommand`: anchored to the end, case-insensitive, the phrase's words
    /// separated by any run of spaces or commas, trailing punctuation allowed. The first word
    /// must start a word, so "over and out" does not match inside "hangover and out".
    static func parseStopPhrase(_ text: String, phrase: String,
                                anchoredToEnd: Bool = true) -> (text: String, matched: Bool) {
        let words = phrase
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(NSRegularExpression.escapedPattern(for:))
        guard !words.isEmpty else { return (text, false) }
        let body = "[\\s,]*(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s,]+") + "(?![\\p{L}\\p{N}])"
        let pattern = anchoredToEnd ? body + "[\\s\\p{P}]*$" : body
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let last = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(last.range, in: text) else {
            return (text, false)
        }
        // Cutting mid-text is only safe near the end: if the file pass misheard the final
        // phrase, the last match found could be one said much earlier, as content.
        let tail = text[range.upperBound...].split(whereSeparator: { $0.isWhitespace })
        guard tail.count <= stopPhraseTailWords else { return (text, false) }
        return (String(text[..<range.lowerBound]), true)
    }

    /// How many words the recorder may catch after the stop phrase and still have them cut.
    static let stopPhraseTailWords = 6

    /// Pause currently-playing media while recording, then resume. Opt-in (default
    /// off): it uses the private MediaRemote API and changes system playback.
    @UserDefault(key: "pauseMediaOnRecord", defaultValue: false)
    var pauseMediaOnRecord: Bool

    /// Lower the system output volume while recording, then restore it. Opt-in.
    @UserDefault(key: "reduceVolumeOnRecord", defaultValue: false)
    var reduceVolumeOnRecord: Bool

    /// Target output volume (0...1) while recording when `reduceVolumeOnRecord` is on.
    @UserDefault(key: "reduceVolumeLevel", defaultValue: 0.1)
    var reduceVolumeLevel: Double

    // Retention / storage policy
    // Limit the number of stored recordings & transcriptions.
    @UserDefault(key: "retentionMaxCountEnabled", defaultValue: false)
    var retentionMaxCountEnabled: Bool

    @UserDefault(key: "retentionMaxCount", defaultValue: 100)
    var retentionMaxCount: Int

    // Delete recordings & transcriptions older than a given age.
    @UserDefault(key: "retentionMaxAgeEnabled", defaultValue: false)
    var retentionMaxAgeEnabled: Bool

    @UserDefault(key: "retentionMaxAgeValue", defaultValue: 30)
    var retentionMaxAgeValue: Int

    // One of RetentionUnit.rawValue: "minutes" | "hours" | "days"
    @UserDefault(key: "retentionMaxAgeUnit", defaultValue: "days")
    var retentionMaxAgeUnit: String

    /// When off, recordings & transcriptions are not persisted (deleted right after use).
    @UserDefault(key: "saveTranscriptionHistory", defaultValue: true)
    var saveTranscriptionHistory: Bool
}
