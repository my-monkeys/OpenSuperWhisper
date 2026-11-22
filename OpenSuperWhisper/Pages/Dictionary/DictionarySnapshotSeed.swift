#if DEBUG
import AppKit
import SwiftUI
import OpenSuperWhisperCore

extension UISnapshotProbe {
    /// Made-up entries for the Dictionary screens, written to the isolated preferences before
    /// the page's view model reads them.
    static func seedDictionary(openEditor: Bool = false,
                               newEntry: (asWord: Bool, original: String, replacement: String)? = nil) {
        AppPreferences.shared.customDictionaryEnabled = true
        AppPreferences.shared.customDictionaryEntries = [
            CustomDictionaryEntry(original: "open super whisper", replacement: "OpenSuperWhisper",
                                  alternates: ["open super wisper"]),
            CustomDictionaryEntry(original: "my monkey", replacement: "My-Monkey",
                                  alternates: ["mai monkey", "my monkeys"]),
            CustomDictionaryEntry(original: "Parakeet", replacement: "Parakeet"),
            CustomDictionaryEntry(original: "Cherith", replacement: "Cherith"),
            CustomDictionaryEntry(original: "new paragraph", replacement: "\\n\\n"),
            CustomDictionaryEntry(original: "open quote", replacement: "“", spacing: .attachesRight),
            CustomDictionaryEntry(original: "([^.?!]+), said ([A-Z]\\w+)", replacement: "“$1,” said $2",
                                  isRegex: true),
        ]
        DictionaryPage.snapshotOpensFirstEntry = openEditor
        DictionaryPage.snapshotNewEntry = newEntry
        DictionaryPage.snapshotFilter = nil
        AppPreferences.shared.suggestDictionaryWords = false
        AppPreferences.shared.dictionarySuggestionsData = nil
        DictionarySuggestions.shared.reload()
    }

    /// The dictionary with words waiting in its Suggested list, shown.
    static func seedSuggestions() {
        seedDictionary()
        AppPreferences.shared.suggestDictionaryWords = true
        AppPreferences.shared.dictionarySuggestionsData = try? JSONEncoder().encode(sampleSuggestions)
        DictionarySuggestions.shared.reload()
        DictionaryPage.snapshotFilter = .suggested
    }

    static let sampleSuggestions = [
        DictionarySuggestion(term: "Kubernetes", heard: "cooper netties"),
        DictionarySuggestion(term: "camille@example.com", heard: "camille at example dot com"),
        DictionarySuggestion(term: "Rsets", heard: "rest sets"),
    ]

    /// The notice after a dictation, over a plain backdrop like the agent panel's.
    static func suggestionNotice(textScale: Double = TextScale.default) -> AnyView {
        AppPreferences.shared.textScale = textScale
        let card = DictionarySuggestionCard(suggestion: sampleSuggestions[2],
                                            onAdd: {}, onRefuse: {}, onClose: {})
            .environment(\.appTextScale, textScale)
            .fixedSize(horizontal: false, vertical: true)
        return AnyView(ZStack(alignment: .bottomTrailing) {
            Color(nsColor: .underPageBackgroundColor)
            card
        })
    }
}
#endif
