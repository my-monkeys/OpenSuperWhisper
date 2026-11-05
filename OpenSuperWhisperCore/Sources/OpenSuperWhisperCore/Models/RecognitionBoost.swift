import Foundation

/// The words recognition is biased toward: the Whisper prompt and Parakeet's vocabulary boost.
///
/// Two lists feed it, each behind its own switch: the dictionary's written forms and the snippet
/// triggers (#167). A snippet only fires when its trigger is heard word for word, so helping the
/// model hear it is worth having, but boosting is off by default for both: on Parakeet any boost
/// at all moves the file pass from the offline decoder to the sliding-window one.
///
/// Snippet triggers come with the clip (`TranscriptionSettings.snippetTriggers`) rather than from
/// the preferences, because only a dictation expands them: a dropped file or a CLI run would
/// otherwise be pushed toward phrases nothing then replaces.
public enum RecognitionBoost {

    /// The lists in priority order — dictionary, snippets, then the field — without repeating a
    /// term that differs only in case.
    ///
    /// The field's terms come last because they are the weakest evidence: a name the user has
    /// actually put in their dictionary should win the spelling when the two disagree. They are
    /// also the only list that changes per dictation, which is why the caller caps them against
    /// what the first two already cost rather than capping the merged list (#89).
    public static func terms(dictionary: [String], snippets: [String],
                             field: [String] = []) -> [String] {
        var seen = Set<String>()
        return (dictionary + snippets + field).filter { seen.insert($0.lowercased()).inserted }
    }
}

extension CorePreferences {
    /// The dictionary's terms when its boost is on, for the engines that read preferences
    /// directly (Parakeet's file pass, the live preview).
    public var dictionaryBoostTerms: [String] {
        customDictionaryEnabled && customDictionaryBoostEnabled
            ? CustomDictionary.boostTerms(entries: customDictionaryEntries) : []
    }
}
