import XCTest

@testable import OpenSuperWhisperCore

/// Folding rules that write the same thing into one badge.
///
/// Before rules could hold several phrasings, saying a thing three ways meant three rows all
/// writing "My Monkey". The merge has to be lossless: every phrasing that used to work must
/// still work afterwards, or the user silently loses replacements they rely on.
final class DictionaryMergeTests: CoreTestCase {

    func testRulesWritingTheSameThingBecomeOne() {
        let merged = CustomDictionary.merged([
            CustomDictionaryEntry(original: "my monkey", replacement: "My Monkey"),
            CustomDictionaryEntry(original: "mymonkey", replacement: "My Monkey"),
            CustomDictionaryEntry(original: "my-monkey", replacement: "My Monkey"),
        ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].triggers, ["my monkey", "mymonkey", "my-monkey"])
    }

    /// The point of the merge is that nothing stops working.
    func testEveryPhrasingStillReplaces() {
        let merged = CustomDictionary.merged([
            CustomDictionaryEntry(original: "my monkey", replacement: "My Monkey"),
            CustomDictionaryEntry(original: "mymonkey", replacement: "My Monkey"),
        ])

        for spoken in ["my monkey", "mymonkey"] {
            XCTAssertEqual(CustomDictionary.apply("about \(spoken) today", entries: merged),
                           "about My Monkey today")
        }
    }

    func testDifferentResultsStayApart() {
        let merged = CustomDictionary.merged([
            CustomDictionaryEntry(original: "git hub", replacement: "GitHub"),
            CustomDictionaryEntry(original: "my monkey", replacement: "My Monkey"),
        ])

        XCTAssertEqual(merged.count, 2)
    }

    /// Same character, opposite pull: an opening and a closing quote must not collapse together.
    func testSameCharacterWithDifferentSpacingStaysApart() {
        let merged = CustomDictionary.merged([
            CustomDictionaryEntry(original: "open quote", replacement: "\"",
                                  spacing: .attachesRight),
            CustomDictionaryEntry(original: "close quote", replacement: "\"",
                                  spacing: .attachesLeft),
        ])

        XCTAssertEqual(merged.count, 2)
    }

    /// Casing of the result is meaningful: "github" and "GitHub" are different outputs.
    func testResultsDifferingOnlyByCaseStayApart() {
        let merged = CustomDictionary.merged([
            CustomDictionaryEntry(original: "a", replacement: "GitHub"),
            CustomDictionaryEntry(original: "b", replacement: "github"),
        ])

        XCTAssertEqual(merged.count, 2)
    }

    /// A duplicate phrasing must not be listed twice on the merged rule.
    func testRepeatedPhrasingsAreNotDuplicated() {
        let merged = CustomDictionary.merged([
            CustomDictionaryEntry(original: "my monkey", replacement: "My Monkey"),
            CustomDictionaryEntry(original: "My Monkey", replacement: "My Monkey"),
        ])

        XCTAssertEqual(merged[0].triggers, ["my monkey"])
    }

    /// Half-filled rows are someone mid-edit. Collapsing them would delete their work.
    func testUnfinishedRowsAreLeftAlone() {
        let merged = CustomDictionary.merged([
            CustomDictionaryEntry(original: "one", replacement: ""),
            CustomDictionaryEntry(original: "two", replacement: ""),
        ])

        XCTAssertEqual(merged.count, 2)
    }

    func testAlternatesOnBothSidesSurvive() {
        let merged = CustomDictionary.merged([
            CustomDictionaryEntry(original: "a", replacement: "X", alternates: ["b"]),
            CustomDictionaryEntry(original: "c", replacement: "X", alternates: ["d"]),
        ])

        XCTAssertEqual(merged[0].triggers, ["a", "b", "c", "d"])
    }

    func testOrderOfFirstAppearanceIsKept() {
        let merged = CustomDictionary.merged([
            CustomDictionaryEntry(original: "z", replacement: "Zebra"),
            CustomDictionaryEntry(original: "a", replacement: "Apple"),
            CustomDictionaryEntry(original: "zz", replacement: "Zebra"),
        ])

        XCTAssertEqual(merged.map(\.replacement), ["Zebra", "Apple"])
    }

    func testMergingIsStableWhenNothingSharesAResult() {
        let entries = [
            CustomDictionaryEntry(original: "a", replacement: "A"),
            CustomDictionaryEntry(original: "b", replacement: "B"),
        ]

        XCTAssertEqual(CustomDictionary.merged(entries), entries)
    }
}
