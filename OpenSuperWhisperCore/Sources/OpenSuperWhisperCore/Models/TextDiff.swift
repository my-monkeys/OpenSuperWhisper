import Foundation

/// A word-level diff between the text the engine wrote and the one the cleanup shipped, for the
/// history's "Original" panel and the report card (#277). `CorrectionDiff` is not reusable here:
/// it looks for the user's own corrections in a field and drops punctuation and spacing, while
/// this one has to give back every character of both texts so the view can show them in one flow.
public enum TextDiff {
    public enum Kind: Equatable, Sendable {
        case unchanged, removed, added
    }

    public struct Segment: Equatable, Sendable {
        public let kind: Kind
        public let text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Cleanups rewrite whole dictations: past this many tokens on a side the quadratic table
    /// gets large for a screen that only wants a hint, so the texts are shown as one replacement.
    static let tokenLimit = 3_000

    /// The segments that rebuild `new` when read without the removed ones, and `old` when read
    /// without the added ones. Tokens are runs of letters or digits, runs of whitespace, and
    /// single punctuation marks, so a comma that appeared is a change of its own and not a new
    /// spelling of the word before it.
    public static func segments(from old: String, to new: String) -> [Segment] {
        let before = tokens(of: old), after = tokens(of: new)
        guard before.count <= tokenLimit, after.count <= tokenLimit else {
            return [Segment(.removed, old), Segment(.added, new)].filter { !$0.text.isEmpty }
        }
        return merged(script(before, after))
    }

    static func tokens(of text: String) -> [String] {
        enum Class { case word, space, mark }
        func classify(_ character: Character) -> Class {
            if character.isLetter || character.isNumber { return .word }
            return character.isWhitespace ? .space : .mark
        }
        var tokens: [String] = []
        var current = ""
        var currentClass: Class?
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            // An apostrophe inside a word ("i'll", "l'été") belongs to it: split there, "I'll"
            // would show as three changed pieces for one capital letter.
            let insideWord = currentClass == .word && (character == "'" || character == "\u{2019}")
                && index + 1 < characters.count && characters[index + 1].isLetter
            let next = insideWord ? .word : classify(character)
            if let currentClass, next == currentClass, next != .mark || insideWord {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(character)
                currentClass = next
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Longest-common-subsequence edit script, removals before additions inside one change.
    private static func script(_ a: [String], _ b: [String]) -> [Segment] {
        let width = b.count + 1
        var lengths = [Int](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i * width + j] = a[i] == b[j]
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var out: [Segment] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                out.append(Segment(.unchanged, a[i])); i += 1; j += 1
            } else if j == b.count || (i < a.count && lengths[(i + 1) * width + j] >= lengths[i * width + j + 1]) {
                out.append(Segment(.removed, a[i])); i += 1
            } else {
                out.append(Segment(.added, b[j])); j += 1
            }
        }
        return out
    }

    /// Adjacent tokens of one kind become one segment. A space between two removed words, or two
    /// added ones, joins their change instead of leaving a gap of plain text inside it.
    private static func merged(_ script: [Segment]) -> [Segment] {
        var result: [Segment] = []
        for (index, segment) in script.enumerated() {
            if let last = result.last, last.kind == segment.kind {
                result[result.count - 1] = Segment(last.kind, last.text + segment.text)
            } else if segment.kind == .unchanged, segment.text.allSatisfy(\.isWhitespace), let last = result.last,
                      last.kind != .unchanged, index + 1 < script.count, script[index + 1].kind == last.kind {
                result[result.count - 1] = Segment(last.kind, last.text + segment.text)
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
