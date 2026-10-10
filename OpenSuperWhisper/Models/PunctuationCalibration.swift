import Foundation
import OpenSuperWhisperCore

/// Learns how someone says punctuation by having them read a sentence we chose.
///
/// Telling a user to add a rule saying "open quote" imposes our phrasing on them. Someone
/// dictating fiction in French says "ouvrez les guillemets", or "guillemets", or nothing at all.
/// Reading a sentence we already know the shape of turns that guesswork into a comparison: the
/// target says where every mark belongs, the transcript says what they said in its place.
///
/// The target also settles spacing, which is otherwise the hard part. `«` in `dit « bonjour »`
/// has a space before and none after, so it glues right; `»` is the reverse. Nothing has to be
/// inferred from the words.
enum PunctuationCalibration {

    /// A sentence to read aloud. Deliberately ordinary prose: someone reads "he said" naturally
    /// and reads punctuation the way they normally would, which is the thing being measured.
    struct Sentence: Identifiable, Equatable {
        let id: String
        let language: String
        let text: String
    }

    struct DerivedRule: Equatable {
        /// What the person actually said, verbatim from the transcript.
        let spoken: String
        /// The character it stood in for.
        let mark: String
        let spacing: CustomDictionaryEntry.Spacing
    }

    // MARK: - What we ask people to read

    /// Four per language: enough to cover the marks that matter in prose without turning the
    /// screen into an exam.
    static func sentences(for language: String) -> [Sentence] {
        language.hasPrefix("fr") ? french : english
    }

    /// Every mark is separated from the next by at least one word. Two marks in a row share one
    /// stretch of transcript and cannot be told apart, so `He said, "hello."` would teach
    /// nothing. That constraint is why these read slightly plainly.
    static let english: [Sentence] = [
        Sentence(id: "en-1", language: "en",
                 text: "He said \"hello\" and walked away."),
        Sentence(id: "en-2", language: "en",
                 text: "She had one rule: nobody waits."),
        Sentence(id: "en-3", language: "en",
                 text: "He arrived late (again) and said nothing."),
        Sentence(id: "en-4", language: "en",
                 text: "He was late; nobody minded."),
    ]

    static let french: [Sentence] = [
        Sentence(id: "fr-1", language: "fr",
                 text: "Il a dit « bonjour » puis il est parti."),
        Sentence(id: "fr-2", language: "fr",
                 text: "Elle n'a donné qu'une consigne : personne n'attend."),
        Sentence(id: "fr-3", language: "fr",
                 text: "Il est arrivé en retard (encore) et n'a rien dit."),
        Sentence(id: "fr-4", language: "fr",
                 text: "Il était en retard ; personne n'a rien dit."),
    ]

    // MARK: - Deriving rules

    /// Marks we make rules for.
    ///
    /// Deliberately not the comma or the full stop. The model writes those by itself most of the
    /// time, so a rule turning a spoken "virgule" into a comma lands beside one that is already
    /// there and gives `oui, ,`. Knowing whether a mark is wanted or already present takes more
    /// than a find and replace, and until that exists these are the marks the model does not
    /// insert on its own: nobody gets a semicolon they did not ask for.
    static let learnableMarks: Set<Character> = [":", ";", "«", "»", "\"", "(", ")"]

    /// Everything treated as punctuation when splitting words apart, learnable or not.
    ///
    /// The target sentences end in a full stop and the transcripts will too. Both have to come
    /// off before the words can be lined up, whether or not a rule comes out of it: otherwise
    /// "parti." never matches "parti" and the alignment drifts from there on.
    static let punctuation: Set<Character> = [
        ",", ".", ":", ";", "?", "!", "\"", "«", "»", "—", "…", "(", ")",
    ]

    /// Compares a sentence we asked for with what came back, and reports what stood in for each
    /// mark. Returns nothing for marks the person did not speak, which is the common case when
    /// the model punctuated by itself.
    static func derive(expected: String, heard: String) -> [DerivedRule] {
        let target = parse(expected)
        let spokenWords = words(in: heard)

        let targetWords = target.compactMap { item -> String? in
            if case .word(let w) = item { return w }
            return nil
        }
        let anchors = align(targetWords, spokenWords)

        var rules: [DerivedRule] = []
        var wordIndex = 0
        var index = 0

        while index < target.count {
            if case .word = target[index] {
                wordIndex += 1
                index += 1
                continue
            }

            // Marks with no word between them share one stretch of transcript, and there is no
            // honest way to say which words belong to which. `He said, "hello"` gives "comma
            // open quote" for both. Skipping beats guessing: a wrong rule is then applied to
            // everything the user dictates afterwards. The sentences we ship keep marks apart
            // so this stays rare.
            var run: [(mark: String, spacing: CustomDictionaryEntry.Spacing, learnable: Bool)] = []
            while index < target.count, case .mark(let mark, let spacing, let learnable) = target[index] {
                run.append((mark, spacing, learnable))
                index += 1
            }

            // A run of one, and one we actually teach. The full stop closing every sentence is
            // parsed so the words line up, then dropped here: whatever the reader said in its
            // place is theirs to keep, not a rule we want to write.
            guard run.count == 1, run[0].learnable else { continue }

            // The words said here sit between the target word before the mark and the one
            // after, wherever those landed in the transcript.
            let start = wordIndex == 0 ? 0 : anchors[wordIndex - 1].map { $0 + 1 }
            let end = anchors.indices.contains(wordIndex) ? anchors[wordIndex] : spokenWords.count
            guard let from = start, let to = end, from < to, to <= spokenWords.count else {
                continue
            }

            let spoken = spokenWords[from..<to].joined(separator: " ")
            guard !spoken.isEmpty, spoken.count <= 40 else { continue }

            rules.append(DerivedRule(spoken: spoken, mark: run[0].mark, spacing: run[0].spacing))
        }

        return dedupe(rules)
    }

    /// Groups what was learned into dictionary rules, one per mark, gathering every phrasing
    /// that produced it. Reading four sentences that each contain a comma should leave one comma
    /// rule, not four.
    static func entries(from rules: [DerivedRule]) -> [CustomDictionaryEntry] {
        // Keyed by mark *and* spacing: an opening and a closing quote are the same character
        // pulling in opposite directions, and merging them would make one of the two wrong.
        struct Key: Hashable {
            let mark: String
            let spacing: CustomDictionaryEntry.Spacing
        }

        var order: [Key] = []
        var spokenByKey: [Key: [String]] = [:]

        for rule in rules {
            let key = Key(mark: rule.mark, spacing: rule.spacing)
            if spokenByKey[key] == nil {
                order.append(key)
                spokenByKey[key] = []
            }
            let known = spokenByKey[key]!
            if !known.contains(where: { $0.caseInsensitiveCompare(rule.spoken) == .orderedSame }) {
                spokenByKey[key]!.append(rule.spoken)
            }
        }

        return order.compactMap { key in
            guard let spoken = spokenByKey[key], let first = spoken.first else { return nil }
            return CustomDictionaryEntry(original: first,
                                         replacement: key.mark,
                                         alternates: Array(spoken.dropFirst()),
                                         spacing: key.spacing)
        }
    }

    // MARK: - Parsing the target

    private enum Item {
        case word(String)
        /// `learnable` is false for the marks we split words on but do not teach, such as the
        /// full stop ending every sentence.
        case mark(String, CustomDictionaryEntry.Spacing, learnable: Bool)
    }

    /// Splits the target into words and marks, reading each mark's spacing off the sentence.
    private static func parse(_ text: String) -> [Item] {
        var items: [Item] = []
        var current = ""
        let characters = Array(text)

        func flush() {
            if !current.isEmpty {
                items.append(.word(current))
                current = ""
            }
        }

        for (index, character) in characters.enumerated() {
            if character.isWhitespace {
                flush()
                continue
            }
            guard punctuation.contains(character) else {
                current.append(character)
                continue
            }

            // An apostrophe-like hyphen inside a word ("demanda-t-il") is part of the word, not
            // a mark someone reads aloud.
            let previous = index > 0 ? characters[index - 1] : " "
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if character == "-" && previous.isLetter && next.isLetter {
                current.append(character)
                continue
            }

            flush()
            let spaceBefore = index == 0 || characters[index - 1].isWhitespace
            let spaceAfter = index + 1 >= characters.count || characters[index + 1].isWhitespace
            items.append(.mark(String(character),
                               spacing(before: spaceBefore, after: spaceAfter),
                               learnable: learnableMarks.contains(character)))
        }
        flush()

        return items
    }

    /// A mark with a space before it and none after opens something, so it glues to what
    /// follows. The reverse closes something. Marks with space on both sides (French `« »`,
    /// `;`, `?`) keep their spaces, which is what French typography wants.
    private static func spacing(before spaceBefore: Bool,
                                after spaceAfter: Bool) -> CustomDictionaryEntry.Spacing {
        if spaceBefore && !spaceAfter { return .attachesRight }
        if !spaceBefore && spaceAfter { return .attachesLeft }
        return .standalone
    }

    // MARK: - Comparing

    /// Words only, with the model's own punctuation stripped: the person spoke the punctuation,
    /// so anything the model wrote as a character is noise for this comparison.
    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { token in
                String(token.unicodeScalars.filter {
                    !punctuation.contains(Character($0)) || Character($0) == "-"
                })
            }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty }
    }

    private static func normalise(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// For each target word, where it landed in the transcript, or nil when it never did.
    /// A longest-common-subsequence alignment, so a misheard word in the middle shifts nothing
    /// after it.
    private static func align(_ target: [String], _ spoken: [String]) -> [Int?] {
        let a = target.map(normalise)
        let b = spoken.map(normalise)

        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var result = [Int?](repeating: nil, count: a.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                result[i] = j
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    private static func dedupe(_ rules: [DerivedRule]) -> [DerivedRule] {
        var seen = Set<String>()
        return rules.filter { seen.insert("\($0.mark)|\(normalise($0.spoken))").inserted }
    }
}
