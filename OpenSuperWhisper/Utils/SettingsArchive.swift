import Foundation
import OpenSuperWhisperCore

/// The settings file people export, import, and sync through a gist.
///
/// A JSON object with a format tag and the preference values, keyed by their UserDefaults name.
/// Values that UserDefaults keeps as `Data` hold JSON in practice (dictionary, snippets, rules),
/// so they are written as that JSON under `"$json"` to stay readable in a gist; anything else
/// stored as `Data` goes under `"$data"` as base64.
///
/// API keys live in the Keychain and are never part of it.
enum SettingsArchive {
    static let format = "opensuperwhisper-settings"
    static let version = 1
    static let fileName = "opensuperwhisper-settings.json"

    enum ReadError: LocalizedError {
        case notASettingsFile
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .notASettingsFile:
                return String(localized: "This file is not an OpenSuperWhisper settings file.")
            case .newerVersion:
                return String(localized: "These settings come from a newer version of OpenSuperWhisper. Update the app, then try again.")
            }
        }
    }

    /// Preferences that describe this Mac or this install rather than how someone likes to
    /// dictate: devices and screen positions, file paths, caches, one-time flags. Every other key
    /// `AppPreferences` writes travels. `SettingsArchiveTests` checks both lists together cover
    /// every key, so a new preference has to be placed in one of them.
    static let localKeys: Set<String> = [
        "agentDisabledProjects",
        "agentRecentProjects",
        "cachedRemoteModels",
        "debugMode",
        "dictionarySuggestionsData",
        "didSeedAppContextPresets",
        "feedbackPromptDone",
        "feedbackPromptLaunches",
        "groqModel",
        "hasCompletedOnboarding",
        "indicatorCustomAnchor",
        "lastModifierOnlyHotkey",
        "lastMouseButtonHotkey",
        "selectedMicrophoneData",
        "selectedWhisperModelPath",
    ]

    static let portableKeys: [String] = [
        "addSpaceAfterSentence", "agentAskOnPermission", "agentAskOnQuestion", "agentAskOnStop",
        "agentEnabledKinds", "agentWaitSeconds", "aiBackend", "aiOllamaEndpoint", "aiOllamaModel",
        "aiPostProcessingClosing", "aiPostProcessingEnabled", "aiPostProcessingPrompt",
        "aiPostProcessingTranslation", "aiRemoteEndpoint", "aiRemoteModel", "appAppearance",
        "appContextFormattingEnabled", "appContextProfilesData", "appInsertionRulesData",
        "appModelRules", "autoCopyToClipboard", "autoPasteTranscription", "beamSize",
        "builtInModelFileName", "clipboardRestoreDelayMs", "contextAwareModelMode",
        "customDictionaryBoostEnabled", "customDictionaryData", "customDictionaryEnabled",
        "dictionaryRefusedWords", "escCancelWithoutConfirmation", "fillerWordsPattern",
        "fluidAudioModelVersion", "glassBubbleSize", "holdRecordingTriggers", "holdToRecord",
        "indicatorLayout", "indicatorMeterMode", "indicatorPosition", "initialPrompt",
        "latchRecordingWithSpace", "liveTranscriptionEnabled", "matchTextAroundCaret",
        "modifierOnlyHotkey", "mouseButtonHotkey", "noSpeechThreshold", "notifyWhenNoPasteTarget",
        "pasteAgentPromptsInPieces", "pasteInsteadOfTyping", "pasteIntoOriginalField",
        "pasteListsAsRichText", "pauseMediaOnRecord", "playSoundOnRecordStart", "playSoundOnRecordStop",
        "postRecordHookCommand", "postRecordHookEnabled", "recordingTriggers", "reduceVolumeLevel",
        "reduceVolumeOnRecord", "remoteFallbackEnabled", "remoteFallbackModelData",
        "remoteServerModel", "remoteServerTimeoutEnabled", "remoteServerTimeoutSeconds",
        "remoteServerURL", "remoteUserPresets", "removeFillerWords", "retentionMaxAgeEnabled",
        "retentionMaxAgeUnit", "retentionMaxAgeValue", "retentionMaxCount",
        "retentionMaxCountEnabled", "saveTranscriptionHistory", "selectedEngine",
        "settingsAdvancedRubrics", "showCancelButtonOnIndicator", "showStopButtonOnIndicator",
        "showTimestamps", "snippetsBoostEnabled", "snippetsData", "snippetsEnabled", "startHidden",
        "stopPhrase", "stopPhraseSilenceMs", "stopPhraseSubmits", "submitModifierChord",
        "submitModifierOnlyHotkey", "submitMouseButtonHotkey", "submitOnVoiceCommand",
        "suggestDictionaryWords", "suppressBlankAudio", "temperature", "textScale",
        "translateToEnglish", "typingPaceMilliseconds", "uiTheme", "unloadBuiltInModelWhenIdle",
        "unloadWhisperModelWhenIdle", "useAsianAutocorrect", "useBeamSearch",
        "useSurroundingTextAsContext", "whisperLanguage", "writingStyleID", "customWritingStylesData",
        "appWritingStyles",
    ]

    /// The portable preferences set in `defaults`, as the file's bytes. Keys left at their
    /// default are absent, so importing the file leaves them alone on the other Mac.
    static func export(from defaults: UserDefaults, appVersion: String, now: Date = Date()) throws -> Data {
        var settings: [String: Any] = [:]
        for key in portableKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            settings[key] = jsonValue(value)
        }
        let file: [String: Any] = [
            "format": format,
            "version": version,
            "app": appVersion,
            "exportedAt": ISO8601DateFormatter().string(from: now),
            "settings": settings,
        ]
        return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
    }

    /// The preference values in a settings file, ready for `apply`. Keys this version does not
    /// carry, local ones included, are dropped.
    static func read(_ data: Data) throws -> [String: Any] {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              file["format"] as? String == format,
              let fileVersion = file["version"] as? Int,
              let settings = file["settings"] as? [String: Any]
        else { throw ReadError.notASettingsFile }
        guard fileVersion <= version else { throw ReadError.newerVersion(fileVersion) }
        let portable = Set(portableKeys)
        var values: [String: Any] = [:]
        for (key, value) in settings where portable.contains(key) {
            if let stored = storedValue(value) { values[key] = stored }
        }
        return values
    }

    static func apply(_ values: [String: Any], to defaults: UserDefaults) {
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
    }

    private static func jsonValue(_ value: Any) -> Any {
        guard let data = value as? Data else { return value }
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return ["$json": json]
        }
        return ["$data": data.base64EncodedString()]
    }

    private static func storedValue(_ value: Any) -> Any? {
        guard let wrapped = value as? [String: Any], wrapped.count == 1 else { return value }
        if let json = wrapped["$json"] {
            return try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
        }
        if let base64 = wrapped["$data"] as? String {
            return Data(base64Encoded: base64)
        }
        return value
    }
}
