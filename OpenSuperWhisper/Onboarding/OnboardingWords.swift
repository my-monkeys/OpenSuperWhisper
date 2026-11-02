import Foundation
import OpenSuperWhisperCore

/// The rules of the "Your words" step, pure so tests pin them.
enum OnboardingWords {
    /// Enough to fill a dictionary from day one; more is what the Dictionary page is for.
    static let limit = 20

    /// `words` with `raw` added, or unchanged when it is blank, already there, already in the
    /// dictionary or the list is full.
    static func adding(_ raw: String, to words: [String], existing: [CustomDictionaryEntry]) -> [String] {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, words.count < limit, !contains(word, in: words),
              !isKnown(word, in: existing) else { return words }
        return words + [word]
    }

    /// What Continue appends to the dictionary: plain "word" entries, the way the Dictionary
    /// page stores a New word (the word is both the trigger and the replacement), minus any
    /// the dictionary gained in the meantime.
    static func entries(for words: [String], existing: [CustomDictionaryEntry]) -> [CustomDictionaryEntry] {
        words.filter { !isKnown($0, in: existing) }
            .map { CustomDictionaryEntry(original: $0, replacement: $0) }
    }

    /// Whether an entry already hears or writes the word, however it is cased.
    static func isKnown(_ word: String, in entries: [CustomDictionaryEntry]) -> Bool {
        entries.contains { entry in
            contains(word, in: entry.triggers + [entry.trimmedReplacement])
        }
    }

    private static func contains(_ word: String, in list: [String]) -> Bool {
        list.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }
}

extension OnboardingViewModel {
    /// The account's full name, offered as a chip to tap: names are what a model misspells
    /// most. Gone once it is added or already in the dictionary.
    var suggestedWord: String? {
        let name = system.fullUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, OnboardingWords.adding(name, to: words, existing: AppPreferences.shared.customDictionaryEntries)
            != words else { return nil }
        return name
    }

    var wordLimitReached: Bool { words.count >= OnboardingWords.limit }

    func addWord(_ raw: String) {
        words = OnboardingWords.adding(raw, to: words, existing: AppPreferences.shared.customDictionaryEntries)
    }

    /// Turns what is typed into a chip; the field empties even when the word is a duplicate.
    func addWordDraft() {
        addWord(wordDraft)
        wordDraft = ""
    }

    func removeWord(_ word: String) {
        words.removeAll { $0 == word }
    }

    /// Continue: writes the chips, with the field's pending text, to the dictionary and turns it
    /// on, since it ships off and words in a dictionary that is off do nothing. Skip never gets
    /// here, so it writes nothing.
    func commitWords() {
        addWordDraft()
        let prefs = AppPreferences.shared
        let existing = prefs.customDictionaryEntries
        let added = OnboardingWords.entries(for: words, existing: existing)
        guard !added.isEmpty else { return }
        prefs.customDictionaryEntries = existing + added
        prefs.customDictionaryEnabled = true
        NotificationCenter.default.post(name: .customDictionaryDidChange, object: nil)
    }
}
