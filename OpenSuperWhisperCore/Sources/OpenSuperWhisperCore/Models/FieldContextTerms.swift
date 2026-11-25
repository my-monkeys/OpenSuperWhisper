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

        let memoisedSpelling = memoised(spelling)
        let tokens = words(in: text)
        var seen = Set<String>()
        var result: [String] = []

        var index = 0
        while index < tokens.count {
            var consumed = 1
            // Longest run first: "Claude Code" is one name, not two words.
            for length in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let slice = tokens[index..<(index + length)]

                // A run cannot continue past punctuation the tokeniser trimmed from a word's
                // end: "Cherith, Nyiragongo" is two names, not one. Only a trailing trim counts,
                // so "(Nyiragongo Cherith" keeps its leading bracket and is still one name.
                guard !slice.dropLast().contains(where: { $0.endsRun }) else { continue }
                // A run cannot cross a sentence end. "Cherith. Nyiragongo" is two names in two
                // sentences, not one name of two words — joining them would put a term in the
                // vocabulary that the user never wrote, and consume the second name doing it.
                // The flag is computed from the previous raw word plus the gap, so a line break
                // counts.
                guard !slice.dropFirst().contains(where: { $0.startsSentence }) else { continue }

                let run = slice.map {
                    CorrectionDiff.Word($0.text, startsSentence: $0.startsSentence)
                }
                // The flag decides what `isVocabulary` answers for the words inside a run, but
                // not what this reducer emits: a word admitted only because the flag lets a
                // dictionary-known capital count is exactly the word `survivesFieldGuard` drops,
                // and every word that survives is vocabulary on its own. Fusion is the only shape
                // the flag's reach can still take; the strong-shape recall it now costs is stated
                // in `survivesFieldGuard`.
                guard run.allSatisfy({ admitsToRun($0.text) }),
                      let candidate = DictionaryCandidates.term(
                          from: run, spelling: memoisedSpelling,
                          capitalMarksNames: capitalMarksNames)
                else { continue }

                // A run emits only a contiguous slice of its survivors. "Code" falls out of
                // "Claude Code" and "Claude" stays, but a word dropped from the middle separates
                // two names instead of letting the reducer invent the pair: "Cherith Bay
                // Nyiragongo" is "Cherith" and "Nyiragongo", never "Cherith Nyiragongo".
                let candidateWords = candidate.split(separator: " ").map(String.init)
                let kept = candidateWords.map { survivesFieldGuard($0, spelling: memoisedSpelling) }
                guard let first = kept.firstIndex(of: true),
                      let last = kept.lastIndex(of: true),
                      kept[first...last].allSatisfy({ $0 })
                else { continue }

                let term = candidateWords[first...last].joined(separator: " ")
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
    /// - A strong shape is evidence only while the spelling dictionary does not already know the
    ///   word as written ("iOS", "eBay", "GPT4"). This is what stops "PDF" and "USA" being
    ///   boosted next to a real name. It costs recall for acronyms and brands the OS dictionary
    ///   spells — those stop being boosted — but the engine already writes those words, and the
    ///   user's dictionary is the escape hatch for the rest.
    /// - A word that does not start with a capital or a digit is dropped unless its shape is
    ///   evidence on its own: in someone's own prose a lowercase unknown is as likely a typo as
    ///   jargon, but a lowercase-initial name with an inner capital is a name.
    /// - A capitalised word with no strong shape survives only when its lowercase form is
    ///   unknown. "Cherith" stays; "Parakeet" — and "Maxim" — do not. `isVocabulary` deliberately
    ///   keeps the latter, and that stays right for a dictionary suggestion. This is also what
    ///   rejects the nouns of a language that capitalises every one of them: a German noun is a
    ///   known word in lowercase, so its capital buys it nothing here.
    private static func survivesFieldGuard(_ word: String,
                                           spelling: DictionaryCandidates.Spelling) -> Bool {
        // Shape is evidence only while the dictionary does not already know the word: "PDF" and
        // "USA" are spelled right already, so boosting them only makes a near neighbour likelier
        // to be rewritten. Asked as written, the way `isVocabulary` asks about a strong shape.
        if DictionaryCandidates.hasStrongShape(word) { return !spelling.knows(word) }
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

    /// One word of the field, with the two boundary facts a run needs.
    private struct Token {
        let text: String
        /// First word of a sentence, where a capital is grammar rather than spelling.
        let startsSentence: Bool
        /// Punctuation was trimmed from this word's end, so nothing after it belongs to the same
        /// run. A trim at the front does not count: "(Nyiragongo Cherith" is one name.
        var endsRun: Bool
    }

    /// The words of the field's text, each with whether a sentence starts at it.
    ///
    /// The trimming is `CorrectionDiff.core(of:)` — the rule the correction watch already uses,
    /// so the two cannot disagree about where a word ends. `@`, `#`, `&` and `_` survive it,
    /// which is what tells `DictionaryCandidates` a token is a handle, a flag or a path rather
    /// than a word.
    ///
    /// The sentence flag is `CorrectionDiff.endsSentence(previousRaw + gap)`, gap included. The
    /// whitespace split loses a line break, and a line break ends a run; passing only the
    /// previous word would make one-name-per-line lists fuse.
    private static func words(in text: String) -> [Token] {
        var result: [Token] = []
        var raw = ""
        /// The whitespace between the previous word and `raw`.
        var gap = ""
        var previousRaw: String?

        func flush() {
            guard !raw.isEmpty else { return }
            let core = CorrectionDiff.core(of: raw)
            if core.isEmpty {
                // A token that is nothing but punctuation ("—", "…", ",,") separates the words
                // on either side, and a sentence mark among it still ends a sentence for the
                // word after it.
                if !result.isEmpty { result[result.count - 1].endsRun = true }
                previousRaw = raw
            } else {
                // The first word starts a sentence; after it the previous raw word plus the gap
                // decide, so a line break the whitespace split discards still counts.
                let startsSentence: Bool
                if result.isEmpty {
                    startsSentence = true
                } else {
                    startsSentence = CorrectionDiff.endsSentence((previousRaw ?? "") + gap)
                }
                result.append(Token(text: core, startsSentence: startsSentence,
                                    endsRun: !raw.hasSuffix(core)))
                previousRaw = raw
            }
            raw = ""
        }

        for character in text {
            if character.isWhitespace {
                if raw.isEmpty {
                    gap.append(character)
                } else {
                    flush()
                    gap = String(character)
                }
            } else {
                raw.append(character)
            }
        }
        flush()
        return result
    }

    // MARK: - Spelling lookups

    /// One spelling dictionary for one reduction, asking the injected `knows` at most once per
    /// distinct form.
    ///
    /// The reducer offers a word as the start of up to three runs and `isVocabulary` asks about
    /// it again inside each; a 48-word title-case field made 562 lookups. The cache lives for one
    /// call and is never shared, so `Spelling`'s single-caller contract still holds.
    private static func memoised(_ spelling: DictionaryCandidates.Spelling)
        -> DictionaryCandidates.Spelling {
        let cache = KnownWords()
        return DictionaryCandidates.Spelling(
            knows: { cache.answer(for: $0, spelling: spelling) },
            correctsTypo: spelling.correctsTypo)
    }

    private final class KnownWords {
        private var answers: [String: Bool] = [:]

        func answer(for word: String, spelling: DictionaryCandidates.Spelling) -> Bool {
            if let known = answers[word] { return known }
            let answer = spelling.knows(word)
            answers[word] = answer
            return answer
        }
    }
}
