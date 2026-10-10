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
            .quote([.paragraph("Careful.")]),
            .rule,
        ])
    }

    /// The reply that came out as one run-on paragraph: the dashes inline, the blank quote lines gone.
    func testQuoteKeepsItsParagraphsAndList() {
        let blocks = MarkdownBlock.parse("""
        Version courte :

        > Bonjour Alex,
        >
        > Les retours sont en ligne (https://example.com) :
        >
        > - **Boutons** : « Valider » et « Annuler » suivent les couleurs du thème.
        > - **Fenêtre** : uniquement le contenu, en pleine hauteur.
        >
        > **Dernier point** : l'option n'est pas proposée. Ça te va ?
        """)
        XCTAssertEqual(blocks, [
            .paragraph("Version courte :"),
            .quote([
                .paragraph("Bonjour Alex,"),
                .paragraph("Les retours sont en ligne (https://example.com) :"),
                .bullet(items: [
                    "**Boutons** : « Valider » et « Annuler » suivent les couleurs du thème.",
                    "**Fenêtre** : uniquement le contenu, en pleine hauteur.",
                ]),
                .paragraph("**Dernier point** : l'option n'est pas proposée. Ça te va ?"),
            ]),
        ])
    }

    func testQuoteOfOneParagraphStillJoinsItsLines() {
        XCTAssertEqual(MarkdownBlock.parse("> one\n>two\n> three"), [.quote([.paragraph("one two three")])])
    }

    func testNestedQuote() {
        XCTAssertEqual(MarkdownBlock.parse("> outer\n>\n> > inner"), [
            .quote([.paragraph("outer"), .quote([.paragraph("inner")])]),
        ])
    }

    func testCodeInAQuoteKeepsItsIndentation() {
        let blocks = MarkdownBlock.parse("""
        > ```swift
        > if ok {
        >     run()
        > }
        > ```
        """)
        XCTAssertEqual(blocks, [.quote([.code(language: "swift", text: "if ok {\n    run()\n}")])])
    }

    func testWrappedListItemInAQuoteStaysWithItsItem() {
        XCTAssertEqual(MarkdownBlock.parse("> - a\n>   wrapped\n> - b"), [.quote([.bullet(items: ["a wrapped", "b"])])])
    }

    func testEmptyQuoteIsDropped() {
        XCTAssertEqual(MarkdownBlock.parse("before\n\n>\n> \n\nafter"), [.paragraph("before"), .paragraph("after")])
    }

    func testTextAroundAQuoteIsUntouched() {
        let blocks = MarkdownBlock.parse("""
        Before.
        - a
        > quoted
        after, not quoted
        """)
        XCTAssertEqual(blocks, [
            .paragraph("Before."),
            .bullet(items: ["a"]),
            .quote([.paragraph("quoted")]),
            .paragraph("after, not quoted"),
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
