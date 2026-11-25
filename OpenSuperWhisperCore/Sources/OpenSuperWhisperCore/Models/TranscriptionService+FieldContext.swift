import Foundation

/// Field-context resolution for `TranscriptionService` (#89): which engines may see the focused
/// field, and in what shape. Split out of `TranscriptionService.swift` so that file stays the
/// dispatch path — selection, loading, the engine gate — while this one decides what the field is
/// allowed to contribute.
///
/// Sits beside `FieldContext.swift` because the two are one decision: this file picks the value,
/// `FieldContext` carries it, and `TranscriptionService` re-checks it against the engine that
/// actually ran before dispatch.
extension TranscriptionService {
    /// The language the spelling dictionary should judge the field's words in, or nil for "the
    /// user's own languages".
    ///
    /// The clip's language, not the app's preference: a dictation transcribed in French must not
    /// have its field checked against whichever language happened to be selected earlier.
    ///
    /// "auto" maps to nil, because it is not a language a dictionary can look a word up in — the
    /// engine detects it from audio that had not been spoken when this text was written. Nil asks
    /// the dictionary for the user's preferred languages, which is what the old preference-read
    /// path did whenever the preference was "auto", and is the only honest answer available.
    ///
    /// The keyboard-layout selection code never reaches here: `DictationPipeline.process`
    /// resolves it into a concrete language before these settings are built.
    nonisolated static func spellingLanguage(for selectedLanguage: String) -> String? {
        selectedLanguage == "auto" ? nil : selectedLanguage
    }

    /// What this engine is allowed to see of the field, or nil when it is allowed nothing.
    ///
    /// The two gates are deliberate: the preference (the user asked) and the conformance (this
    /// engine has somewhere to put it). Neither alone is a reason to hand over someone's
    /// document. A non-conforming engine reaches the `nil` return and is then called with the
    /// plain `transcribeAudio(url:settings:)` — the argument is never passed, which is the
    /// defensive strip in its only honest form.
    func resolveFieldContext(_ text: String?, for engine: TranscriptionEngine,
                             settings: TranscriptionSettings) -> FieldContext? {
        guard let text = TranscriptionPrompt.surroundingText(
            enabled: settings.useSurroundingTextAsContext, captured: text) else { return nil }

        // The mode, not only the conformance. The capture gate already refused to read the field
        // for an engine that cannot use it, but that is one layer, and the layer that is easy to
        // bypass — a test stub, a future engine, a fallback path. Checking the selected id here
        // means a conforming engine selected as `remote` still receives nothing, so the refusal
        // holds even when the gate did not run.
        guard EngineCapabilities.supportsFieldContext(engine: CoreAccess.preferences.selectedEngine)
        else { return nil }

        if engine is ProseContextEngine { return .prose(text) }
        // The spelling pass runs only here: a prose engine returned above, and an engine with
        // nowhere to put a term list returns below without one.
        guard engine is TermContextEngine else { return nil }
        let terms = FieldContextTerms.terms(
            from: text,
            spelling: CoreAccess.fieldTermSpelling(
                Self.spellingLanguage(for: settings.selectedLanguage)),
            capitalMarksNames: LanguageUtil.marksNamesWithCapitals(settings.selectedLanguage))
        return terms.isEmpty ? nil : .terms(terms)
    }
}
