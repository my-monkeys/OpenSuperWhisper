import Foundation

/// Turns the text already written in the focused field into terms worth boosting (#89).
///
/// Whisper takes free text, so the field's prose reaches it whole. Parakeet takes a vocabulary
/// list, so the prose has to be reduced to the words that look like names; this is that
/// reduction and nothing else.
///
/// Pure, deterministic and platform-neutral: the spelling dictionary is injected, so the answer
/// does not depend on the machine's installed languages. It reuses `DictionaryCandidates`, the
/// heuristic the dictionary-suggestion path already ships, with two narrowings that make sense
/// only for prose — see `survivesFieldGuard`.
public enum FieldContextTerms {

    /// The terms to boost, in the order they first appear, at most `limit` of them.
    ///
    /// First occurrence is the selection order on purpose: at 240 characters the cap is the
    /// ordinary path, not an edge case, so "which ten survive" has to be a stable answer a test
    /// can assert rather than whatever a set happens to iterate first.
    public static func terms(from text: String,
                             spelling: DictionaryCandidates.Spelling,
                             capitalMarksNames: Bool,
                             limit: Int = 10) -> [String] {
        guard !text.isEmpty, limit > 0 else { return [] }

        let words = words(in: text)
        var seen = Set<String>()
        var result: [String] = []

        var index = 0
        while index < words.count {
            var consumed = 1
            // Longest run first: "Claude Code" is one name, not two words.
            for length in stride(from: min(3, words.count - index), through: 1, by: -1) {
                let run = Array(words[index..<(index + length)])
                // The flag decides two different things, and only one of them is the word we
                // emit. `term(from:)` also asks `isVocabulary` whether *any* word in the run is
                // evidence, and the flag changes that answer for a capitalised word whose
                // as-written form the dictionary knows. The guard below drops most such words
                // from the output — but a run they admitted still emits the words that survive,
                // so the flag reaches the answer through candidacy even when the word that
                // admitted it is dropped.
                guard run.allSatisfy({ admitsToRun($0.text) }),
                      let candidate = DictionaryCandidates.term(
                          from: run, spelling: spelling, capitalMarksNames: capitalMarksNames)
                else { continue }

                // The guard is per word, so "Code" falls out of "Claude Code" and "Claude"
                // stays. A run with no survivors falls through to a shorter one rather than
                // consuming words that might each stand on their own.
                let survivors = candidate.split(separator: " ")
                    .map(String.init)
                    .filter { survivesFieldGuard($0, spelling: spelling) }
                guard !survivors.isEmpty else { continue }

                let term = survivors.joined(separator: " ")
                if seen.insert(term.lowercased()).inserted {
                    result.append(term)
                    if result.count == limit { return result }
                }
                consumed = length
                break
            }
            index += consumed
        }
        return result
    }

    // MARK: - Narrowings that are specific to prose

    /// The two field-only narrowings (#89). `isVocabulary` answers "would the user like this
    /// added to their dictionary", following a correction they made and can decline. A field of
    /// prose is much weaker evidence, and a wrong term is not a suggestion — it changes what the
    /// engine hears, including words the user never said.
    ///
    /// - A word that does not start with a capital or a digit is dropped, unless its shape is
    ///   evidence on its own ("iOS", "eBay"): in someone's own prose a lowercase unknown is as
    ///   likely a typo as jargon, but a lowercase-initial name with an inner capital is a name.
    /// - A capitalised word with no strong shape survives only when its lowercase form is
    ///   unknown. "Cherith" stays; "Parakeet" — and "Maxim" — do not. `isVocabulary` deliberately
    ///   keeps the latter, and that stays right for a dictionary suggestion. This is also what
    ///   rejects the nouns of a language that capitalises every one of them: a German noun is a
    ///   known word in lowercase, so its capital buys it nothing here.
    private static func survivesFieldGuard(_ word: String,
                                           spelling: DictionaryCandidates.Spelling) -> Bool {
        // Shape is evidence on its own, whatever the first character is: "iOS", "macOS" and
        // "eBay" carry an inner capital and are exactly the product names this exists for. This
        // is the only door open to a lowercase-initial word. The other one stays shut — a
        // lowercase word with no shape is still dropped, because in someone's prose it is as
        // likely a typo as jargon.
        if DictionaryCandidates.hasStrongShape(word) { return true }
        guard startsName(word) else { return false }
        return !spelling.knows(word.lowercased())
    }

    /// A word a run may start with — the same precondition `DictionaryCandidates.term` applies
    /// to a multi-word name, widened for the one case it cannot express: a lowercase-initial
    /// name whose capital is inside the word. `term` still applies its own rules to the run.
    private static func admitsToRun(_ word: String) -> Bool {
        startsName(word) || DictionaryCandidates.hasStrongShape(word)
    }

    private static func startsName(_ word: String) -> Bool {
        word.first.map { $0.isUppercase || $0.isNumber } ?? false
    }

    // MARK: - Tokenising

    /// The words of the field's text, each with whether a sentence starts at it.
    ///
    /// Connecting punctuation is trimmed from both ends — a name followed by a comma is the same
    /// name — but `@`, `#`, `_`, `-` and `/` are left alone, because they are what tells
    /// `DictionaryCandidates` a token is a handle, a flag or a path rather than a word.
    ///
    /// The flag matters because a capital at a sentence start is grammar, not spelling, and the
    /// heuristic treats it that way. Over-marking a sentence start makes the reducer more
    /// conservative, never less.
    private static func words(in text: String) -> [CorrectionDiff.Word] {
        var result: [CorrectionDiff.Word] = []
        var startsSentence = true
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let trimmed = String(raw).trimmingCharacters(in: edgePunctuation)
            guard !trimmed.isEmpty else { continue }
            result.append(CorrectionDiff.Word(trimmed, startsSentence: startsSentence))
            // A closing quote after the full stop does not stop it ending the sentence.
            let terminator = raw.reversed().first { !"\"')]}”’".contains($0) }
            startsSentence = terminator.map { ".!?".contains($0) } ?? false
        }
        return result
    }

    private static let edgePunctuation =
        CharacterSet(charactersIn: ".,;:!?\"'`()[]{}<>«»„“”‘’…—–")
}
