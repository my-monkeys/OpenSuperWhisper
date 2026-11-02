import XCTest
@testable import OpenSuperWhisperCore

final class TextDiffTests: XCTestCase {
    private func diff(_ old: String, _ new: String) -> [TextDiff.Segment] {
        TextDiff.segments(from: old, to: new)
    }

    /// Reading the segments back must give both texts, whatever the changes were.
    private func assertRoundTrip(_ old: String, _ new: String, file: StaticString = #filePath, line: UInt = #line) {
        let segments = diff(old, new)
        XCTAssertEqual(segments.filter { $0.kind != .added }.map(\.text).joined(), old, file: file, line: line)
        XCTAssertEqual(segments.filter { $0.kind != .removed }.map(\.text).joined(), new, file: file, line: line)
    }

    func testIdenticalTextsAreOneUnchangedSegment() {
        XCTAssertEqual(diff("Send it tomorrow.", "Send it tomorrow."), [.init(.unchanged, "Send it tomorrow.")])
    }

    func testEmptyTexts() {
        XCTAssertEqual(diff("", ""), [])
        XCTAssertEqual(diff("", "new"), [.init(.added, "new")])
        XCTAssertEqual(diff("old", ""), [.init(.removed, "old")])
    }

    func testDeletionOfAFillerWord() {
        XCTAssertEqual(diff("so um send it", "so send it"),
                       [.init(.unchanged, "so "), .init(.removed, "um "), .init(.unchanged, "send it")])
    }

    func testInsertion() {
        XCTAssertEqual(diff("send it", "send it now"),
                       [.init(.unchanged, "send it"), .init(.added, " now")])
    }

    func testReplacementShowsTheOldWordThenTheNewOne() {
        XCTAssertEqual(diff("the mock ups are ready", "the mockups are ready"),
                       [.init(.unchanged, "the "), .init(.removed, "mock ups"), .init(.added, "mockups"),
                        .init(.unchanged, " are ready")])
    }

    func testPunctuationOnlyChangeLeavesTheWordsAlone() {
        XCTAssertEqual(diff("meet on Thursday shall we", "meet on Thursday, shall we"),
                       [.init(.unchanged, "meet on Thursday"), .init(.added, ","), .init(.unchanged, " shall we")])
    }

    func testRoundTripOnARealCleanup() {
        assertRoundTrip("i'll send you the mock ups tomorrow morning thanks for the feedback shall we meet on thursday",
                        "I'll send you the mockups tomorrow morning. Thanks for the feedback, shall we meet on Thursday?")
        assertRoundTrip("  leading and\ttabbed  ", "leading and tabbed")
    }

    func testAccentsAndScriptsStayWholeWords() {
        XCTAssertEqual(diff("c'est déjà fait", "c'est déjà fini"),
                       [.init(.unchanged, "c'est déjà "), .init(.removed, "fait"), .init(.added, "fini")])
    }

    func testAnApostropheStaysInsideItsWord() {
        XCTAssertEqual(TextDiff.tokens(of: "i'll l\u{2019}été 'quoted'"), ["i'll", " ", "l\u{2019}été", " ", "'", "quoted", "'"])
        XCTAssertEqual(diff("i'll go", "I'll go"), [.init(.removed, "i'll"), .init(.added, "I'll"), .init(.unchanged, " go")])
    }

    func testHugeTextsFallBackToOneReplacement() {
        let old = Array(repeating: "word", count: TextDiff.tokenLimit).joined(separator: " ")
        XCTAssertEqual(diff(old, "short").map(\.kind), [.removed, .added])
    }
}
