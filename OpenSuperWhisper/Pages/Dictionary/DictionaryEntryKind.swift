import SwiftUI
import OpenSuperWhisperCore

/// How the Dictionary page presents an entry. Derived from the stored rule, never stored: the
/// persisted format stays `CustomDictionaryEntry` as it always was.
enum DictionaryEntryKind {
    /// Its only trigger is the word itself, so it rewrites nothing and only feeds the
    /// recognition boost (and fixes the casing).
    case word
    /// Rewrites what the model writes into something else.
    case correction
    /// A replacement holding a line break, such as "new paragraph".
    case command
    /// A regular expression.
    case pattern

    /// Whether a new entry of this kind starts with "Also help recognition of this word" on. A
    /// correction's rule already writes its replacement, and boosting that replacement is what
    /// made Parakeet hear "Maxim" for "Mais"; only a word has nothing else to make it heard.
    var boostsByDefault: Bool { self == .word }

    var label: LocalizedStringKey {
        switch self {
        case .word: return "New word"
        case .correction: return "Correction"
        case .command: return "Command"
        case .pattern: return "Pattern"
        }
    }

    var foreground: Color {
        switch self {
        case .word: return STheme.ok
        case .correction: return STheme.accent
        case .command, .pattern: return STheme.hint
        }
    }

    var background: Color {
        switch self {
        case .word: return STheme.okBg
        case .correction: return STheme.accentSoft
        case .command, .pattern: return STheme.fill
        }
    }
}

extension CustomDictionaryEntry {
    var trimmedReplacement: String {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replacements are stored with `\n` typed as two characters (see `CustomDictionary.unescaped`),
    /// and an older rule could hold a real line break.
    var writesLineBreak: Bool {
        replacement.contains("\n") || replacement.contains("\\n")
    }

    /// An entry as a new one is created: its recognition switch set the way its kind starts.
    func withDefaultBoost() -> CustomDictionaryEntry {
        var entry = self
        entry.boostsRecognition = kind.boostsByDefault
        return entry
    }

    var kind: DictionaryEntryKind {
        if isRegex { return .pattern }
        if writesLineBreak { return .command }
        let triggers = triggers
        if triggers.isEmpty || triggers == [trimmedReplacement] { return .word }
        return .correction
    }
}

/// The filter chips above the list. Suggested shows the words offered from corrections (#169),
/// which are not entries yet.
enum DictionaryFilter: Hashable {
    case all, words, corrections, suggested

    func includes(_ entry: CustomDictionaryEntry) -> Bool {
        switch self {
        case .all: return true
        case .words: return entry.kind == .word
        case .corrections: return entry.kind != .word
        case .suggested: return false
        }
    }
}
