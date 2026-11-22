import Foundation

/// The words recognition is biased toward: the Whisper prompt and Parakeet's vocabulary boost.
///
/// Two lists feed it: the written forms of the dictionary entries that steer recognition (each
/// entry has its own switch), and the snippet triggers (#167, behind their own switch). A snippet
/// only fires when its trigger is heard word for word, so helping the model hear it is worth
/// having, but boosting is off by default for snippets: on Parakeet any boost at all moves the
/// file pass from the offline decoder to the sliding-window one.
///
/// Snippet triggers come with the clip (`TranscriptionSettings.snippetTriggers`) rather than from
/// the preferences, because only a dictation expands them: a dropped file or a CLI run would
/// otherwise be pushed toward phrases nothing then replaces.
public enum RecognitionBoost {

    /// Both lists, the dictionary first, without repeating a term that differs only in case.
    public static func terms(dictionary: [String], snippets: [String]) -> [String] {
        var seen = Set<String>()
        return (dictionary + snippets).filter { seen.insert($0.lowercased()).inserted }
    }
}

extension CorePreferences {
    /// The terms of the dictionary entries that steer recognition, for the engines that read
    /// preferences directly (Parakeet's file pass, the live preview).
    public var dictionaryBoostTerms: [String] {
        customDictionaryEnabled
            ? CustomDictionary.boostTerms(entries: customDictionaryEntries) : []
    }
}
