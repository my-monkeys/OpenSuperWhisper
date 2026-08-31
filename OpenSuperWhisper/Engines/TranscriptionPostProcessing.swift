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
enum TranscriptionPostProcessing {

    /// Trims, applies Asian autocorrect and the custom dictionary, and reports silence.
    ///
    /// The order is not arbitrary: autocorrect rewrites spacing inside CJK text, and dictionary
    /// rules match on word boundaries, so running the dictionary first would have it matching
    /// against spacing that is about to change.
    static func finish(_ text: String, settings: Settings) -> String {
        var processed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if settings.shouldApplyAsianAutocorrect && !processed.isEmpty {
            processed = AutocorrectWrapper.format(processed)
        }

        if settings.shouldApplyCustomDictionary {
            processed = CustomDictionary.apply(processed, entries: settings.customDictionaryEntries)
        }

        return processed.isEmpty ? TranscriptionResult.noSpeech : processed
    }
}
