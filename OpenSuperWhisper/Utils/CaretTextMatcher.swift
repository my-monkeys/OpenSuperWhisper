import Foundation
import OpenSuperWhisperCore

/// Fits a dictation to the text around the caret of the field it goes into (#163).
///
/// The engine writes every dictation as a sentence of its own, capital first and period last.
/// Dictated into the middle of a sentence that gives "the review is Tomorrow at noon." with a
/// capital and a period to delete by hand, and dictated right after a word it glues the two
/// together. Pure, so every case is tested without a field.
enum CaretTextMatcher {

    /// - Parameters:
    ///   - text: the dictation after post-processing. Spaces at its ends are recomputed from
    ///     the field, which replaces the unconditional one `addSpaceAfterSentence` leaves.
    ///   - properNouns: words and phrases whose capital is part of the spelling, here the
    ///     dictionary's terms. Words capitalised mid-sentence in the field or in the dictation
    ///     itself are added: the engine capitalises every first word, so case alone cannot tell
    ///     "Paris" from "Tomorrow", but the rest of the text can.
    ///   - adjustCase: false where a capital mid-sentence is the spelling, see `adjustsCase(language:)`.
    ///     The final mark and the spaces are still fitted.
    ///   - keepsFinalMark: the text ends with something the user wrote word for word (a
    ///     snippet, #167), so its last mark is part of it rather than the engine's period.
    static func fit(_ text: String, into field: TextAroundCaret, properNouns: Set<String> = [],
                    adjustCase: Bool = true, keepsFinalMark: Bool = false) -> String {
        let core = trimmingHorizontalSpace(text)
        guard !core.isEmpty else { return text }

        // A selection's own edge spaces stay where they were: double-clicking a word selects
        // the space after it in many apps, and the replacement should not eat it.
        let selected = field.selected
        let leading = String(selected.prefix(while: isHorizontalSpace))
        let trailing = selected.allSatisfy(isHorizontalSpace)
            ? "" : String(selected.reversed().prefix(while: isHorizontalSpace).reversed())
        let before = field.before + leading
        let after = trailing + field.after

        let nouns = properNouns
            .union(capitalisedWords(in: field.before))
            .union(capitalisedWords(in: field.after))
            .union(capitalisedWords(in: core))
        var fitted = adjustCase
            ? matchingCase(core, before: before, replacing: selected, properNouns: nouns) : core
        if continuesSentence(after) && !keepsFinalMark { fitted = droppingFinalMark(fitted) }
        if needsLeadingSpace(before: before, dictation: fitted) { fitted = " " + fitted }
        if needsTrailingSpace(dictation: fitted, after: after) { fitted += " " }
        return leading + fitted + trailing
    }

    // MARK: - Case

    /// German and Luxembourgish capitalise every noun, so a capital in the middle of a sentence
    /// is usually the spelling, and words the field has not shown capitalised yet cannot be told
    /// apart from the engine's sentence start. Their case is left as the engine wrote it. An
    /// unknown language is fitted: the guess is the caller's to make.
    static func adjustsCase(language: String?) -> Bool {
        // One implementation, in core, because the field-term reducer needs the same answer and
        // cannot reach an AppKit-side helper.
        LanguageUtil.marksNamesWithCapitals(language)
    }

    /// The first letter as the place calls for: the case of the first letter of a selection
    /// being replaced, else lowercase when the caret is inside a sentence.
    static func matchingCase(_ core: String, before: String, replacing selected: String,
                             properNouns: Set<String>) -> String {
        if let replaced = selected.first(where: { !isHorizontalSpace($0) }), replaced.isLetter {
            return replaced.isUppercase ? capitalisingFirst(core)
                                        : lowercasingFirst(core, properNouns: properNouns)
        }
        return endsSentence(before) ? core : lowercasingFirst(core, properNouns: properNouns)
    }

    /// Whether what comes next starts a sentence. The start of the field and a line break count:
    /// a new line or a new message is written as one, and so does a line holding only a list,
    /// heading or quote marker ("- ", "## ", "1) ", "> "). Quotes and brackets are looked
    /// through, so `He said "` is mid-sentence and `It ended." ` is not.
    static func endsSentence(_ before: String) -> Bool {
        for character in before.reversed() {
            if character.isNewline { return true }
            if isHorizontalSpace(character) || quotesAndBrackets.contains(character) { continue }
            return sentenceEnds.contains(character) || isMarkerLine(lastLine(of: before))
        }
        return true
    }

    /// Whether a line holds only list, heading or quote markers, each followed by a space: what
    /// precedes the first word of a bullet, a numbered item, a task, a Markdown heading or a
    /// quoted reply. A marker with no space after it is something else: a tag ("#release"), a
    /// hyphenated word.
    static func isMarkerLine(_ line: Substring) -> Bool {
        guard line.utf8.count <= maxMarkerLineLength, let last = line.last, isHorizontalSpace(last) else {
            return false
        }
        // A task box's own space would split it in two.
        let tokens = line.replacingOccurrences(of: "[ ]", with: "[x]").split(whereSeparator: isHorizontalSpace)
        return !tokens.isEmpty && tokens.allSatisfy(isMarker)
    }

    private static func isMarker(_ token: Substring) -> Bool {
        if token.allSatisfy(bulletMarks.contains) { return true }
        if token.count <= 6, token.allSatisfy({ $0 == "#" }) { return true }
        if token == "[x]" || token == "[X]" { return true }
        guard let mark = token.last, mark == "." || mark == ")" else { return false }
        let number = token.dropLast()
        return (1...3).contains(number.count) && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }

    private static func lastLine(of text: String) -> Substring {
        text.lastIndex(where: \.isNewline).map { text[text.index(after: $0)...] } ?? text[...]
    }

    /// Lowercases a word capitalised only for starting the dictation. Left alone: "I" and its
    /// contractions, words with a capital elsewhere (acronyms, "GitHub", "McDonald"), proper
    /// nouns, and a title or an initial in front of a name.
    static func lowercasingFirst(_ core: String, properNouns: Set<String>) -> String {
        let word = core.prefix(while: \.isLetter)
        guard let first = word.first, first.isUppercase,
              !word.dropFirst().contains(where: \.isUppercase),
              word != "I",
              !isTitleOrInitial(word, in: core),
              !properNouns.contains(where: { startsWith(core, $0) }) else { return core }
        return first.lowercased() + String(core.dropFirst())
    }

    /// "Mr. Smith", "Dr. Who", "J. K. Rowling": the abbreviation is part of the name after it,
    /// which the period and the capital that follows show.
    private static func isTitleOrInitial(_ word: Substring, in core: String) -> Bool {
        guard word.count == 1 || titleAbbreviations.contains(String(word)) else { return false }
        let rest = core.dropFirst(word.count)
        guard rest.first == "." else { return false }
        return rest.dropFirst().drop(while: isHorizontalSpace).first?.isUppercase ?? false
    }

    static func capitalisingFirst(_ core: String) -> String {
        guard let first = core.first, first.isLowercase else { return core }
        let upper = first.uppercased()
        // "ß" would become "SS": one letter turned into two is not a capital, it is a rewrite.
        return upper.count == 1 ? upper + String(core.dropFirst()) : core
    }

    /// Words starting with a capital where no sentence starts, which is what a proper noun
    /// looks like. The first word of the text is not counted: where it starts is unknown.
    static func capitalisedWords(in text: String) -> Set<String> {
        var words = Set<String>()
        var word = ""
        var atSentenceStart = true
        // The current line up to the word being read, to see a list marker in front of it. Not
        // grown past what a marker line can be: longer, it can only be text.
        var line = ""
        var lineBeforeWord = ""
        func endWord() {
            guard let first = word.first else { return }
            if !atSentenceStart, first.isUppercase, !isMarkerLine(lineBeforeWord[...]) { words.insert(word) }
            atSentenceStart = false
            word = ""
        }
        for character in text {
            if character.isLetter {
                if word.isEmpty { lineBeforeWord = line }
                word.append(character)
                if line.utf8.count <= maxMarkerLineLength { line.append(character) }
                continue
            }
            endWord()
            if character.isNewline {
                line = ""
            } else if line.utf8.count <= maxMarkerLineLength {
                line.append(character)
            }
            if character.isNewline || sentenceEnds.contains(character) {
                atSentenceStart = true
            } else if character.isNumber {
                atSentenceStart = false
            }
        }
        endWord()
        return words
    }

    // MARK: - Final mark

    /// Whether the text after the caret carries on the sentence the dictation would end: it
    /// starts with a lowercase word, or with punctuation that a period would only double.
    /// Closing brackets and quotes are looked through, so a dictation inside "(…) tomorrow" or
    /// `"…" and left` loses its period too.
    static func continuesSentence(_ after: String) -> Bool {
        guard let index = after.indices.first(where: {
            !isHorizontalSpace(after[$0]) && !closes(at: $0, in: after)
        }) else { return false }
        let next = after[index]
        return !next.isNewline && (next.isLowercase || continuingPunctuation.contains(next))
    }

    /// A closing bracket or quote, or a straight quote that does not open one.
    private static func closes(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        if closingMarks.contains(character) { return true }
        return (character == "\"" || character == "'") && !opens(at: index, in: text)
    }

    /// Drops one final `.`, `!` or `?`, and the space French puts before the last two. Left
    /// alone: an ellipsis or doubled marks, which were meant, and a period closing an
    /// abbreviation ("a.m.", "e.g.") or an initial ("Plan B."), which is part of the word. A
    /// number is not an initial: "level 5." loses it.
    static func droppingFinalMark(_ core: String) -> String {
        guard let mark = core.last, droppableMarks.contains(mark) else { return core }
        let word = trimmingHorizontalSpace(String(core.dropLast()))
        guard let last = word.last, last.isLetter || last.isNumber else { return core }
        if mark == ".", let lastWord = word.split(whereSeparator: \.isWhitespace).last,
           lastWord.contains(".") || (lastWord.count == 1 && lastWord.first?.isLetter == true) {
            return core
        }
        return word
    }

    // MARK: - Spaces

    /// A space before the dictation, unless the caret follows a space, an opening bracket or
    /// quote, or a mark a word is typed straight after, or the dictation starts with punctuation
    /// that hangs on the word before it.
    static func needsLeadingSpace(before: String, dictation: String) -> Bool {
        guard mayPutSpace(after: before, before: dictation), let next = dictation.first else { return false }
        let isStraightQuote = next == "\"" || next == "'"
        return !hangsOnPreviousWord.contains(next)
            && !(isStraightQuote && !opens(at: dictation.startIndex, in: dictation))
    }

    /// A space after the dictation only when a word, or a mark opening one, follows: at the end
    /// of the field or before punctuation it would be a stray character to delete.
    static func needsTrailingSpace(dictation: String, after: String) -> Bool {
        guard mayPutSpace(after: dictation, before: after), let next = after.first else { return false }
        return next.isLetter || next.isNumber || opens(at: after.startIndex, in: after)
    }

    /// Never next to an existing space, inside a script written without spaces, after an
    /// opening mark, after a mark a word is typed straight after, or after a French elision.
    private static func mayPutSpace(after left: String, before right: String) -> Bool {
        guard let last = left.last, let next = right.first else { return false }
        return !last.isWhitespace && !next.isWhitespace
            && !isSpaceless(last) && !isSpaceless(next)
            && !gluesToNext.contains(last)
            && !endsWithElision(left)
            && !opens(at: left.index(before: left.endIndex), in: left)
    }

    /// "l'", "d'", "j'", "qu'", "jusqu'"…: French drops the vowel and glues the word to the next
    /// one. Only these words: after any other, an apostrophe closes a quote or a possessive
    /// ("the students' "), and the space stays.
    static func endsWithElision(_ text: String) -> Bool {
        guard let last = text.last, last == "'" || last == "’" else { return false }
        let word = String(text.dropLast().reversed().prefix(while: \.isLetter).reversed()).lowercased()
        return elidingWords.contains(word)
    }

    /// Whether the mark at `index` opens something. A straight quote opens when it follows a
    /// space, a bracket or nothing and leads into a word; anywhere else it closes, and an
    /// apostrophe after a letter is part of the word ("students'").
    static func opens(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        if openingMarks.contains(character) { return true }
        guard character == "\"" || character == "'" else { return false }
        let previous = index == text.startIndex ? nil : text[text.index(before: index)]
        let following = text.index(after: index) == text.endIndex ? nil : text[text.index(after: index)]
        let afterBreak = previous.map { $0.isWhitespace || openingMarks.contains($0) } ?? true
        let intoWord = following.map { $0.isLetter || $0.isNumber } ?? true
        return afterBreak && intoWord
    }

    // MARK: - Characters

    static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let droppableMarks: Set<Character> = [".", "!", "?"]
    static let continuingPunctuation: Set<Character> = [",", ";", ":", ".", "!", "?", "…"]
    static let openingMarks: Set<Character> = ["(", "[", "{", "“", "‘", "«", "‹", "„", "‚", "¿", "¡"]
    static let closingMarks: Set<Character> = [")", "]", "}", "”", "’", "»", "›"]
    static let quotesAndBrackets: Set<Character> = openingMarks.union(closingMarks).union(["\"", "'"])
    static let hangsOnPreviousWord: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "…", "%", ")", "]", "}", "”", "’", "»", "›",
    ]
    /// Marks a word is typed straight after: a mention, a tag, a path, a hyphenated word.
    static let gluesToNext: Set<Character> = ["@", "#", "/", "\\", "-", "_"]
    static let bulletMarks: Set<Character> = ["-", "*", "+", "•", "◦", "‣", "–", ">"]
    /// "> > - [ ] " is ten: anything much longer is a line of text, not markers.
    static let maxMarkerLineLength = 24
    static let elidingWords: Set<String> = [
        "c", "d", "j", "l", "m", "n", "s", "t", "qu", "jusqu", "lorsqu", "puisqu", "quoiqu", "presqu",
    ]
    static let titleAbbreviations: Set<String> = [
        "Mr", "Mrs", "Ms", "Mx", "Dr", "Prof", "St", "Sr", "Jr", "Mt", "Rev", "Capt", "Lt", "Col", "Sgt",
        "Mme", "Mlle", "Mgr", "Pr",
    ]

    static func isHorizontalSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }

    static func trimmingHorizontalSpace(_ text: String) -> String {
        let start = text.firstIndex(where: { !isHorizontalSpace($0) }) ?? text.endIndex
        let end = text.lastIndex(where: { !isHorizontalSpace($0) }).map(text.index(after:)) ?? start
        return start < end ? String(text[start..<end]) : ""
    }

    /// Chinese, Japanese and Thai put no space between words, nor around their punctuation.
    static func isSpaceless(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x0E00...0x0E7F).contains(scalar)   // Thai
            || (0x3000...0x30FF).contains(scalar)   // CJK punctuation, Hiragana, Katakana
            || (0x3400...0x4DBF).contains(scalar)   // CJK Extension A
            || (0x4E00...0x9FFF).contains(scalar)   // CJK Unified Ideographs
            || (0xFF00...0xFFEF).contains(scalar)   // Fullwidth forms
    }

    private static func startsWith(_ core: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty, core.hasPrefix(phrase) else { return false }
        return core.dropFirst(phrase.count).first.map { !$0.isLetter } ?? true
    }
}
