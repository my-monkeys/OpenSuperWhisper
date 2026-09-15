import Foundation

/// Picking the transcription language from the keyboard layout instead of a setting.
///
/// Someone writing in two languages in the same hour has to go back into Settings at every
/// switch, or let auto-detect guess from the first seconds of audio, which it gets wrong on a
/// short sentence, on an accent, or between two languages that sound alike. They already change
/// layout to type in the other language, so the answer is there and it was given deliberately.
enum KeyboardLanguage {

    /// Stored in `selectedLanguage` when the layout decides. Not a language, a way of choosing
    /// one, which is why it never reaches an engine: the pipeline resolves it per dictation.
    static let selectionCode = "keyboard"

    static let displayName = "From keyboard layout"

    /// The layout's own language, or nil when the engine cannot transcribe it.
    ///
    /// Only the first declaration counts, and that is the whole design decision here. A layout
    /// declares every language it can type, not a preference order: macOS ABC-AZERTY declares
    /// ninety-five, `fr` first and then Afrikaans, Cebuano, Corsican and the rest of the Latin
    /// script. Scanning past the first entry for something the engine accepts would quietly
    /// transcribe a French speaker as Danish the moment French was unavailable. Falling back to
    /// auto-detect is the honest answer to that.
    ///
    /// Input sources speak BCP 47 (`fr`, `pt-BR`, `zh-Hans`) and the engines speak their own
    /// code lists, so the tag is tried whole and then by its primary subtag. Matching against
    /// the supported list rather than a table of our own means a layout can never select a
    /// language the current engine would reject.
    static func resolve(declared: [String], supported: [String]) -> String? {
        guard let tag = declared.first?.lowercased() else { return nil }
        if supported.contains(tag) { return tag }
        guard let primary = tag.split(separator: "-").first.map(String.init),
              supported.contains(primary)
        else { return nil }
        return primary
    }

    /// What the engine should be told for a dictation, given what the layout resolved to.
    ///
    /// Falling back to auto-detect rather than to nothing: a layout with no usable language is
    /// a Chinese or Japanese input method, or a layout that declares none at all, and guessing
    /// from the audio is still better than transcribing as English by default.
    static func language(for stored: String, resolved: String?) -> String {
        guard stored == selectionCode else { return stored }
        return resolved ?? "auto"
    }

    /// Read the active input source and resolve it in one step, for the engine selected now.
    /// Called at record time, never at transcription time: the layout will often have changed
    /// by then, and the clip belongs to the one that was active when the user spoke.
    static func current(engine: String, fluidAudioModelVersion: String) -> String? {
        let supported = EngineCapabilities.supportedLanguages(
            engine: engine, fluidAudioModelVersion: fluidAudioModelVersion)
        return resolve(declared: KeyboardLayoutProvider.inputSourceLanguages(), supported: supported)
    }
}
