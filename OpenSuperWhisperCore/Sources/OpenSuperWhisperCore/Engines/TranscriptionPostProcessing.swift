import Foundation

/// The steps every engine owes a transcription before it is handed back.
///
/// This existed as the same eight lines copied into each of the four local engines, which is
/// exactly why the fifth never got them: transcriptions from a remote server came back raw, so
/// dictionary rules and Asian autocorrect silently did nothing there while working everywhere
/// else. Reported on #101 by someone using Groq through the Remote engine.
///
/// Having one implementation does not by itself stop a sixth engine from forgetting to call it,
/// so `EveryEngineFinishesTests` checks that they all do.
public enum TranscriptionPostProcessing {

    /// Trims, applies Asian autocorrect and the custom dictionary, and reports silence.
    ///
    /// The order is not arbitrary: autocorrect rewrites spacing inside CJK text, and dictionary
    /// rules match on word boundaries, so running the dictionary first would have it matching
    /// against spacing that is about to change.
    public static func finish(_ text: String, settings: TranscriptionSettings) -> String {
        finish(text, settings: settings, formatText: CoreAccess.formatText)
    }

    /// The host's formatter is a parameter so a test can supply its own. It is only called when
    /// Asian autocorrect applies, so the configuration is read no more often than the Rust
    /// formatter used to be.
    static func finish(_ text: String, settings: TranscriptionSettings,
                       formatText: (String) -> String) -> String {
        var processed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if settings.shouldApplyAsianAutocorrect && !processed.isEmpty {
            processed = formatText(processed)
        }

        if settings.shouldApplyCustomDictionary {
            processed = CustomDictionary.apply(processed, entries: settings.customDictionaryEntries)
        }

        return processed.isEmpty ? TranscriptionResult.noSpeech : processed
    }
}
