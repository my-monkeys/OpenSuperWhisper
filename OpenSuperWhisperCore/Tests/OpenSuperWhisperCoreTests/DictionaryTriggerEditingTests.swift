import XCTest

@testable import OpenSuperWhisperCore

/// Editing the phrasings behind one rule. The badge editor shows them as a flat list, so the
/// primary and its alternates have to behave like one list even though only the primary is
/// stored as `original`.
final class DictionaryTriggerEditingTests: CoreTestCase {

    private func rule() -> CustomDictionaryEntry {
        CustomDictionaryEntry(original: "open quote", replacement: "\"",
                              alternates: ["opening quote", "quote"],
                              spacing: .attachesRight)
    }

    func testRemovingAnAlternateLeavesTheRest() {
        var entry = rule()
        entry.removeTrigger(at: 1)

        XCTAssertEqual(entry.triggers, ["open quote", "quote"])
    }

    /// Blanking the primary would leave a rule that matches nothing while still looking present
    /// in the editor, so the next phrasing takes its place.
    func testRemovingThePrimaryPromotesTheNextPhrasing() {
        var entry = rule()
        entry.removeTrigger(at: 0)

        XCTAssertEqual(entry.original, "opening quote")
        XCTAssertEqual(entry.triggers, ["opening quote", "quote"])
    }

    func testRemovingTheLastPhrasingEmptiesTheRule() {
        var entry = CustomDictionaryEntry(original: "hi", replacement: "Hi")
        entry.removeTrigger(at: 0)

        XCTAssertTrue(entry.triggers.isEmpty)
    }

    /// An index past the end must not trap.
    func testRemovingAMissingPhrasingDoesNothing() {
        var entry = rule()
        entry.removeTrigger(at: 9)

        XCTAssertEqual(entry.triggers, rule().triggers)
    }

    /// A rule with no phrasings left must not start rewriting the transcript.
    func testAnEmptiedRuleMatchesNothing() {
        var entry = CustomDictionaryEntry(original: "hi", replacement: "Hi")
        entry.removeTrigger(at: 0)

        XCTAssertEqual(CustomDictionary.apply("hi there", entries: [entry]), "hi there")
    }

    /// Several phrasings reaching one result is the whole point of the badge.
    func testEveryPhrasingStillReachesTheResult() {
        let entry = rule()
        for spoken in entry.triggers {
            XCTAssertEqual(CustomDictionary.apply("he said \(spoken) yes", entries: [entry]),
                           "he said \"yes")
        }
    }
}
