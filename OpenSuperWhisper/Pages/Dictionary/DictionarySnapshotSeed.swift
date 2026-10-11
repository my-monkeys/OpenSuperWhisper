#if DEBUG
import Foundation
import OpenSuperWhisperCore

extension UISnapshotProbe {
    /// Made-up entries for the Dictionary screens, written to the isolated preferences before
    /// the page's view model reads them.
    static func seedDictionary(openEditor: Bool = false) {
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
    }
}
#endif
