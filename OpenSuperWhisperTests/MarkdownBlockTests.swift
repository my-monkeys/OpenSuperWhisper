import XCTest
@testable import OpenSuperWhisper

/// The agent panel's block parser. Agents answer in Markdown with tables and fenced code, which
/// came out as raw pipes and backticks before.
final class MarkdownBlockTests: XCTestCase {

    func testTableWithHeaderAndRows() {
        let blocks = MarkdownBlock.parse("""
        | Model | WER |
        |---|---:|
        | Ultra | 5.7 |
        | v3 | 5.7 |
        """)
        XCTAssertEqual(blocks, [.table(header: ["Model", "WER"], rows: [["Ultra", "5.7"], ["v3", "5.7"]])])
    }

    func testMixedReply() {
        let blocks = MarkdownBlock.parse("""
        ## Done

        I changed **two** files:
        - `a.swift`
        - `b.swift`

        1. Build
        2. Test

        ```swift
        let x = 1
        ```
        > Careful.

        ---
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Done"),
            .paragraph("I changed **two** files:"),
            .bullet(items: ["`a.swift`", "`b.swift`"]),
            .numbered(items: ["Build", "Test"]),
            .code(language: "swift", text: "let x = 1"),
            .quote("Careful."),
            .rule,
        ])
    }

    func testWrappedParagraphLinesJoin() {
        XCTAssertEqual(MarkdownBlock.parse("one\ntwo\n\nthree"), [.paragraph("one two"), .paragraph("three")])
    }

    func testAPipeInProseIsNotATable() {
        XCTAssertEqual(MarkdownBlock.parse("| not a table"), [.paragraph("| not a table")])
    }

    func testSessionTitlePrefersTheRenamedOne() {
        let transcript = """
        {"type":"ai-title","aiTitle":"Fix the build","sessionId":"s"}
        {"type":"custom-title","customTitle":"release","sessionId":"s"}
        {"type":"ai-title","aiTitle":"Fix the build again","sessionId":"s"}
        """
        XCTAssertEqual(AgentHookCommand.sessionTitle(inTranscript: transcript), "release")
    }

    func testSessionTitleFallsBackToTheGeneratedOne() {
        let transcript = """
        {"type":"ai-title","aiTitle":"First","sessionId":"s"}
        {"type":"user","message":"hi"}
        {"type":"ai-title","aiTitle":"Latest","sessionId":"s"}
        """
        XCTAssertEqual(AgentHookCommand.sessionTitle(inTranscript: transcript), "Latest")
        XCTAssertNil(AgentHookCommand.sessionTitle(inTranscript: "{\"type\":\"user\"}"))
    }
}
