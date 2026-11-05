import Foundation

/// Which corrected words are worth offering for the dictionary (#169).
///
/// Most corrections are not vocabulary: a wrong "there" made "their", a number retyped, a
/// sentence reworded. What the dictionary can help with is a word the engine does not know: a
/// name, a brand, jargon. Those give themselves away by their shape (a capital in the middle of
/// a sentence, a capital inside the word, digits among letters, an address) or by being unknown
/// to the spelling dictionary. Pure: the spelling dictionary is passed in.
public enum DictionaryCandidates {

    /// A term to offer, with what the engine had written instead, for the notice to say.
    public struct Candidate: Equatable, Sendable {
        public let term: String
        public let heard: String

        public init(term: String, heard: String) {
            self.term = term
            self.heard = heard
        }
    }

    /// The spelling dictionary, asked about one word at a time.
    /// `@unchecked Sendable` so the host can hand it to core through a `@Sendable` provider
    /// (`CoreConfiguration.fieldTermSpelling`). The struct is a value holding two closures; the
    /// host builds it on the main actor and the only caller invokes it there, so crossing the
    /// boundary carries no shared mutable state.
    public struct Spelling: @unchecked Sendable {
        /// The word is spelled right, as written, in one of the user's languages.
        public let knows: (String) -> Bool
        /// The spelling dictionary would autocorrect the word into another one: a typo.
        public let correctsTypo: (String) -> Bool

        public init(knows: @escaping (String) -> Bool, correctsTypo: @escaping (String) -> Bool) {
            self.knows = knows
            self.correctsTypo = correctsTypo
        }
    }

    /// One correction rarely holds more than one new term, and a notice per word would be a
    /// barrage after a dictation rewritten by hand.
    public static let maxPerDictation = 3

    /// More separate fixes than this and the user reworked the text rather than corrected the
    /// engine: nothing in it says much about vocabulary, and asking the spelling dictionary
    /// about every changed word would hold up the main thread for nothing.
    public static let maxReplacements = 8

    /// - Parameters:
    ///   - dictated: the text as it went in. A term written exactly so anywhere in it was moved
    ///     or retyped, not corrected: the engine already knew it.
    ///   - capitalMarksNames: false in languages that capitalise every noun, where a capital in
    ///     the middle of a sentence is grammar and says nothing about the word.
    public static func candidates(in replacements: [CorrectionDiff.Replacement], dictated: String,
                                  spelling: Spelling, capitalMarksNames: Bool = true) -> [Candidate] {
        guard replacements.count <= maxReplacements else { return [] }
        let dictatedWords = Set(dictated.split(whereSeparator: \.isWhitespace)
            .map { CorrectionDiff.core(of: String($0)) })
        var seen = Set<String>()
        var result: [Candidate] = []
        for replacement in replacements {
            guard let term = term(from: replacement.written, spelling: spelling,
                                  capitalMarksNames: capitalMarksNames),
                  !term.split(separator: " ").allSatisfy({ dictatedWords.contains(String($0)) }),
                  resembles(term, heard: replacement.heard),
                  seen.insert(term.lowercased()).inserted else { continue }
            result.append(Candidate(term: term, heard: replacement.heard.joined(separator: " ")))
            if result.count == maxPerDictation { break }
        }
        return result
    }

    /// The written run as one term: a single word, or a name of two or three words ("My
    /// Monkey", "Claude Code") where every word is capitalised and at least one is vocabulary.
    static func term(from written: [CorrectionDiff.Word], spelling: Spelling,
                     capitalMarksNames: Bool) -> String? {
        let words = written.map { CorrectionDiff.Word(bareWord($0.text), startsSentence: $0.startsSentence) }
        guard !words.isEmpty, words.allSatisfy({ !isExcludedShape($0.text) }) else { return nil }
        if words.count == 1 {
            let word = words[0]
            return isVocabulary(word.text, startsSentence: word.startsSentence, spelling: spelling,
                                capitalMarksNames: capitalMarksNames) ? word.text : nil
        }
        guard words.allSatisfy({ $0.text.first.map { $0.isUppercase || $0.isNumber } ?? false }),
              words.contains(where: {
                  isVocabulary($0.text, startsSentence: $0.startsSentence, spelling: spelling,
                               capitalMarksNames: capitalMarksNames)
              }) else { return nil }
        return words.map(\.text).joined(separator: " ")
    }

    /// Whether one word looks like vocabulary the engine did not know.
    static func isVocabulary(_ word: String, startsSentence: Bool, spelling: Spelling,
                             capitalMarksNames: Bool) -> Bool {
        if isEmail(word) { return true }
        guard !isExcludedShape(word) else { return false }
        let letters = word.filter(\.isLetter)
        let known = spelling.knows(word)

        // Digits among letters ("GPT4", "M2"), a capital inside the word ("GitHub", "iOS"), an
        // acronym ("OSW"): the shape says it all, unless the spelling dictionary already has it.
        if word.contains(where: \.isNumber) || hasInnerCapital(word)
            || (letters.count >= 2 && letters.allSatisfy(\.isUppercase)) {
            return !known
        }
        guard let first = word.first else { return false }
        if first.isUppercase {
            // At a sentence start the capital is the sentence's, and an unknown word there is
            // as likely a slip ("Thier") as a name: only one no dictionary would fix counts.
            if !known { return !startsSentence || !spelling.correctsTypo(word.lowercased()) }
            // A capital the sentence asks for, or one a noun takes anyway.
            if startsSentence || !capitalMarksNames { return false }
            // Capitalised mid-sentence and known as written. "Monday" and "Paris" are known
            // only capitalised: names the engine writes right on its own. "Parakeet" is a
            // common word the user made a name of, which is the vocabulary worth keeping.
            return spelling.knows(word.lowercased())
        }
        // Lowercase: only a word no dictionary has, and not one it would fix as a typo of
        // another (the user's own slip while correcting).
        return !known && !spelling.correctsTypo(word)
    }

    // MARK: - Resemblance

    /// A misheard word, fixed, keeps much of what the engine wrote: "Superbase" for "supabase",
    /// "cloud code" for "Claude Code", "et lui" for "Eliott". Under this share of letters in
    /// common, the user wrote something else in its place. A chat app can also show its
    /// placeholder once a message is sent, which the watch read as the dictation rewritten:
    /// "Si samedi soir" became "Message Mikaël" (0.38) in Beeper.
    static let minResemblance = 0.4

    /// Whether `term` shares at least `minResemblance` of its letters, in order, with what was
    /// heard. A term with digits or symbols is spoken in other letters ("C++", "k8s", "GPT4")
    /// and always passes, as does a word only added.
    static func resembles(_ term: String, heard: [String]) -> Bool {
        guard !heard.isEmpty, term.allSatisfy({ $0.isLetter || $0 == " " || $0 == "'" || $0 == "’" }) else {
            return true
        }
        let said = letters(of: heard.joined()), written = letters(of: term)
        guard !said.isEmpty else { return true }
        let shared = commonLetterCount(said, written)
        return Double(shared) / Double(max(said.count, written.count)) >= minResemblance
    }

    private static func letters(of text: String) -> [Character] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter(\.isLetter))
    }

    /// Length of the longest run of letters both share in the same order.
    private static func commonLetterCount(_ a: [Character], _ b: [Character]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        for letter in a {
            var row = [0]
            for (j, other) in b.enumerated() {
                row.append(letter == other ? previous[j] + 1 : max(previous[j + 1], row[j]))
            }
            previous = row
        }
        return previous[b.count]
    }

    // MARK: - Shapes

    /// The word without what grammar attaches to it: a French or Italian elided article
    /// ("l’API") and an English possessive ("Rsets’s").
    static func bareWord(_ word: String) -> String {
        var bare = word
        let lowered = bare.lowercased()
        for prefix in elisions {
            for apostrophe in ["'", "’"] where lowered.hasPrefix(prefix + apostrophe) && bare.count > prefix.count + 2 {
                bare = String(bare.dropFirst(prefix.count + 1))
                return stripPossessive(bare)
            }
        }
        return stripPossessive(bare)
    }

    private static let elisions = ["l", "d", "j", "qu", "n", "s", "c", "m", "t", "dell", "all", "nell", "sull"]

    private static func stripPossessive(_ word: String) -> String {
        for suffix in ["'s", "’s"] where word.count > suffix.count + 1 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// Numbers, addresses, paths, file names, handles and code: never vocabulary, whatever
    /// their case.
    static func isExcludedShape(_ word: String) -> Bool {
        if isEmail(word) { return false }
        guard (2...maxTermLength).contains(word.count), word.contains(where: \.isLetter) else { return true }
        return word.hasPrefix("@") || isLink(word) || isFileName(word) || isCode(word) || isQuantity(word)
    }

    /// Whether the word's shape alone says it is a name, whatever a dictionary thinks: an email,
    /// digits among letters ("GPT4"), a capital inside the word ("GitHub"), or an acronym
    /// ("OSW"). The same shapes `isVocabulary` trusts, exposed to the field-term reducer, which
    /// uses them to tell a real name from a common word that was merely capitalised (#89).
    static func hasStrongShape(_ word: String) -> Bool {
        if isEmail(word) { return true }
        guard !isExcludedShape(word) else { return false }
        let letters = word.filter(\.isLetter)
        return word.contains(where: \.isNumber) || hasInnerCapital(word)
            || (letters.count >= 2 && letters.allSatisfy(\.isUppercase))
    }

    /// "package.json", "README.md", "main.swift". A capitalised name with a dot keeps being a
    /// name ("Node.js", "Vue.js"): files are written in lowercase or capitals, products in
    /// title case.
    static func isFileName(_ word: String) -> Bool {
        guard let dot = word.lastIndex(of: "."), dot != word.startIndex else { return false }
        let stem = word[..<dot]
        let fileExtension = word[word.index(after: dot)...]
        guard fileExtensions.contains(String(fileExtension)) else { return false }
        let titleCase = stem.first?.isUppercase == true
            && !stem.dropFirst().isEmpty && stem.dropFirst().allSatisfy { $0.isLetter && $0.isLowercase }
        return !titleCase
    }

    private static let fileExtensions: Set<String> = [
        "md", "json", "swift", "ts", "js", "py", "yaml", "yml", "txt", "pdf", "png", "jpg", "csv",
        "html", "css", "sh",
    ]

    static let maxTermLength = 40

    static func isEmail(_ word: String) -> Bool {
        word.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    /// A URL, a domain or a path. "Node.js" stays a word: only a top-level domain makes a dot an
    /// address.
    static func isLink(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if lowered.contains("://") || lowered.hasPrefix("www.") || lowered.contains("/") { return true }
        guard let dot = lowered.lastIndex(of: "."), dot != lowered.startIndex else { return false }
        return topLevelDomains.contains(String(lowered[lowered.index(after: dot)...]))
    }

    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "ai", "co", "fr", "de", "uk", "be", "ch", "ca",
        "es", "it", "nl", "eu", "us", "me", "info", "biz", "gov", "edu", "html", "php",
    ]

    /// Identifiers and expressions: brackets, operators, underscores, a method call, a flag, or
    /// camelCase with a real word before the first hump ("isEnabled"), which "iPhone" and "eBay"
    /// do not have.
    static func isCode(_ word: String) -> Bool {
        if word.contains(where: { codeCharacters.contains($0) }) { return true }
        if word.contains("::") || word.contains("->") || word.hasPrefix("-") || word.hasPrefix(".")
            || word.hasPrefix("#") { return true }
        guard let first = word.first, first.isLowercase else { return false }
        let prefix = word.prefix(while: \.isLowercase)
        let rest = word.dropFirst(prefix.count)
        return prefix.count >= 2 && rest.first?.isUppercase == true && rest.dropFirst().contains(where: \.isLowercase)
    }

    private static let codeCharacters: Set<Character> = ["{", "}", "(", ")", "[", "]", "<", ">", "=",
                                                         ";", "$", "`", "|", "\\", "_", "*", "~", "^"]

    /// A number with a unit or an ordinal: "3pm", "10x", "2nd", "4K", "12h30".
    static func isQuantity(_ word: String) -> Bool {
        guard word.first?.isNumber == true else { return false }
        return word.filter(\.isLetter).count <= 3
    }

    private static func hasInnerCapital(_ word: String) -> Bool {
        word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
    }
}
