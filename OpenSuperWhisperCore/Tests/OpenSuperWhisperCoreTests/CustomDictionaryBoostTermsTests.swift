import XCTest
@testable import OpenSuperWhisperCore

/// `boostTerms` is the single source of the words boosted on BOTH engines
/// (Whisper prompt-boost + Parakeet decode vocabulary), so its contract is
/// covered directly here.
final class CustomDictionaryBoostTermsTests: CoreTestCase {

    private func entry(_ original: String, _ replacement: String) -> CustomDictionaryEntry {
        CustomDictionaryEntry(original: original, replacement: replacement)
    }

    /// "Maxime" → "Maxim" made Parakeet write "Maxim" for every "Mais": such an entry keeps
    /// its replacement and stops steering recognition.
    func testAnEntryThatOptsOutRewritesButIsNotBoosted() {
        let maxim = CustomDictionaryEntry(original: "Maxime", replacement: "Maxim", boostsRecognition: false)
        let entries = [maxim, entry("cloud flair", "Cloudflare")]
        XCTAssertEqual(CustomDictionary.boostTerms(entries: entries), ["Cloudflare"])
        XCTAssertEqual(CustomDictionary.spellings(entries: entries), ["Maxim", "Cloudflare"])
        XCTAssertEqual(CustomDictionary.apply("salut Maxime", entries: entries), "salut Maxim")
    }

    /// Entries saved before the switch existed keep steering recognition, as they always did.
    func testAnEntrySavedBeforeTheSwitchStillBoosts() throws {
        let json = #"[{"id":"8C1B6D1E-3A2F-4F43-9E0B-7E3D5B6A9C10","original":"Maxime","replacement":"Maxim"}]"#
        let decoded = try JSONDecoder().decode([CustomDictionaryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.boostsRecognition, true)
    }

    func testTheSwitchSurvivesARoundTrip() throws {
        let entry = CustomDictionaryEntry(original: "Maxime", replacement: "Maxim", boostsRecognition: false)
        let data = try JSONEncoder().encode([entry])
        XCTAssertEqual(try JSONDecoder().decode([CustomDictionaryEntry].self, from: data), [entry])
    }

    func testUsesReplacementsAndIgnoresOriginal() {
        let terms = CustomDictionary.boostTerms(entries: [entry("my monkey", "My-Monkey")])
        XCTAssertEqual(terms, ["My-Monkey"])
    }

    func testIncludesBoostOnlyEntriesWithEmptyOriginal() {
        // An entry with no "heard as" still boosts its replacement term.
        let terms = CustomDictionary.boostTerms(entries: [entry("", "Kubernetes")])
        XCTAssertEqual(terms, ["Kubernetes"])
    }

    func testDeduplicatesCaseInsensitivelyPreservingOrder() {
        let terms = CustomDictionary.boostTerms(entries: [
            entry("", "Swift"),
            entry("swiftui", "SwiftUI"),
            entry("", "swift"),   // duplicate of "Swift" (case-insensitive) → dropped
            entry("", "Xcode"),
        ])
        XCTAssertEqual(terms, ["Swift", "SwiftUI", "Xcode"])
    }

    func testFiltersEmptyAndWhitespaceReplacements() {
        let terms = CustomDictionary.boostTerms(entries: [
            entry("", "   "),
            entry("heard", ""),
            entry("", "Valid"),
        ])
        XCTAssertEqual(terms, ["Valid"])
    }

    func testPromptBoostJoinsBoostTermsWithCommas() {
        let entries = [entry("", "Alpha"), entry("", "Beta")]
        XCTAssertEqual(CustomDictionary.promptBoost(entries: entries), "Alpha, Beta")
    }
}
