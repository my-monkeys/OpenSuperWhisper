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

    /// The merged terms and which of them entered from the field.
    ///
    /// Parakeet's rescore path holds field terms to a stricter similarity floor than the
    /// dictionary and the snippets (#307), and that provenance cannot be read back from a text:
    /// a dictionary "Priya" and a field "Priya" merge to the same list. So the merge returns it.
    struct Plan: Equatable {
        /// The lists in priority order — dictionary, snippets, then the field — without
        /// repeating a term that differs only in case.
        let terms: [String]
        /// The lowercased forms that entered from the field list.
        let fieldForms: Set<String>
    }

    /// The merged terms with their provenance. `terms` is the same merge without it.
    ///
    /// The field's terms come last because they are the weakest evidence: a name the user has
    /// actually put in their dictionary should win the spelling when the two disagree. They are
    /// also the only list that changes per dictation, which is why the caller caps them against
    /// what the first two already cost rather than capping the merged list (#89).
    static func plan(dictionary: [String], snippets: [String],
                     field: [String] = []) -> Plan {
        var seen = Set<String>()
        var terms: [String] = []
        var fieldForms = Set<String>()
        func append(_ candidates: [String], fromField: Bool) {
            for candidate in candidates where seen.insert(candidate.lowercased()).inserted {
                terms.append(candidate)
                if fromField { fieldForms.insert(candidate.lowercased()) }
            }
        }
        append(dictionary, fromField: false)
        append(snippets, fromField: false)
        append(field, fromField: true)
        return Plan(terms: terms, fieldForms: fieldForms)
    }

    /// The merged list alone, for the engines and prompts that do not need provenance.
    public static func terms(dictionary: [String], snippets: [String],
                             field: [String] = []) -> [String] {
        plan(dictionary: dictionary, snippets: snippets, field: field).terms
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
