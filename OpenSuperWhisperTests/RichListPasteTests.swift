import AppKit
import XCTest

@testable import OpenSuperWhisper

/// Covers pasting a dictated list as real bullets (#166): which texts hold a list, the HTML and
/// RTF made of it, which apps get them, and that the rich types ride on the lazy paste item of
/// #162 without changing what counts as a landing. The paste runs on a private pasteboard; the
/// developer's real clipboard is never touched.
final class RichListPasteTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private let notes = "com.apple.Notes"
    private let shopping = "We need:\n- bread\n- chips\n- ice cream"

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenSuperWhisperTests." + UUID().uuidString))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func waitFor(_ seconds: TimeInterval) {
        let elapsed = expectation(description: "\(seconds) s elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: seconds + 2)
    }

    private func html(_ text: String) -> String? {
        RichListPaste.blocks(of: text).map(RichListPaste.html)
    }

    // MARK: - What counts as a list

    func testBulletLinesBecomeOneList() {
        XCTAssertEqual(RichListPaste.blocks(of: shopping), [
            .line("We need:"),
            .list(ordered: false, start: 1, items: ["bread", "chips", "ice cream"]),
        ])
    }

    func testNumberedLinesKeepTheirFirstNumber() {
        XCTAssertEqual(RichListPaste.blocks(of: "3. call Anna\n4) book the room"),
                       [.list(ordered: true, start: 3, items: ["call Anna", "book the room"])])
    }

    /// Markdown reads blank lines between items as one loose list, and so does a model's output.
    func testBlankLinesBetweenItemsKeepOneList() {
        XCTAssertEqual(RichListPaste.blocks(of: "* bread\n\n• chips"),
                       [.list(ordered: false, start: 1, items: ["bread", "chips"])])
    }

    func testABulletListAndANumberedListStayApart() {
        XCTAssertEqual(RichListPaste.blocks(of: "- a\n- b\n1. c\n2. d"), [
            .list(ordered: false, start: 1, items: ["a", "b"]),
            .list(ordered: true, start: 1, items: ["c", "d"]),
        ])
    }

    /// Notion turns plain "- [ ] " lines into to-do blocks; bullets would show the brackets.
    func testTaskItemsArePastedPlain() {
        XCTAssertNil(RichListPaste.richText(for: "Today:\n- [ ] call Anna\n- [ ] book the room",
                                            into: "notion.id"))
    }

    func testTextWithoutAListStaysPlain() {
        XCTAssertNil(RichListPaste.blocks(of: "Bread, chips and ice cream."))
        XCTAssertNil(RichListPaste.blocks(of: "First line\nsecond line"))
        // One dash is punctuation more often than a list.
        XCTAssertNil(RichListPaste.blocks(of: "- sure, why not"))
        XCTAssertNil(RichListPaste.blocks(of: "-5 degrees\n-3 tomorrow"))
        XCTAssertNil(RichListPaste.blocks(of: "1.5 litres\n2.5 litres"))
        XCTAssertNil(RichListPaste.blocks(of: "2026. A year\n2027. Another"))
        XCTAssertNil(RichListPaste.blocks(of: "-\n- "))
    }

    /// Flattened, a nested list would lose the levels the plain lines still show.
    func testNestedListsStayPlain() {
        XCTAssertNil(RichListPaste.blocks(of: "- fruit\n  - apples\n- bread"))
        XCTAssertNil(RichListPaste.blocks(of: "- fruit\n\t- apples\n- bread"))
    }

    /// The space the caret fitting puts before a dictation does not hide its first item.
    func testASingleLeadingSpaceStillStartsAList() {
        XCTAssertEqual(RichListPaste.blocks(of: " - a\n- b"),
                       [.list(ordered: false, start: 1, items: ["a", "b"])])
    }

    // MARK: - HTML

    func testHTMLTakesTheFieldsFontAndDeclaresItsCharset() {
        XCTAssertEqual(html(shopping),
                       "<meta charset=\"utf-8\"><div style=\"font: inherit;\"><div>We need:</div>"
                       + "<ul><li>bread</li><li>chips</li><li>ice cream</li></ul></div>")
    }

    func testHTMLNumbersFromTheFirstItemAndEscapesTheText() {
        let made = html("2. <b> & \"c\"\n3. crème brûlée\n\nThanks")
        XCTAssertEqual(made, "<meta charset=\"utf-8\"><div style=\"font: inherit;\">"
                       + "<ol start=\"2\"><li>&lt;b&gt; &amp; &quot;c&quot;</li><li>crème brûlée</li></ol>"
                       + "<div><br></div><div>Thanks</div></div>")
    }

    func testHTMLKeepsTheSpaceBeforeTheFirstWord() {
        XCTAssertEqual(html(" then:\n- a\n- b")?.contains("<div>&nbsp;then:</div>"), true)
    }

    // MARK: - RTF

    /// The text system reads the RTF back as list paragraphs, which is what makes them bullets
    /// in TextEdit, Pages and Notes.
    func testRTFCarriesTheListsToTheTextSystem() throws {
        let rich = try XCTUnwrap(RichListPaste.richText(for: "We need:\n- bread\n- chips\n1. call\n2. book",
                                                        into: notes))
        let read = try XCTUnwrap(NSAttributedString(rtf: rich.rtf, documentAttributes: nil))
        let paragraphs = read.string.components(separatedBy: "\n")
        XCTAssertEqual(paragraphs.first, "We need:")

        var formats: [NSTextList.MarkerFormat] = []
        var location = 0
        for paragraph in paragraphs {
            if location < read.length,
               let style = read.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
               let list = style.textLists.last {
                formats.append(list.markerFormat)
            }
            location += (paragraph as NSString).length + 1
        }
        let ordered = RichListPaste.orderedMarker
        XCTAssertEqual(formats, [.disc, .disc, ordered, ordered])
        // The numbering the plain lines use, in the writer's own markup; the reader drops the
        // written-out markers and draws them from the list.
        XCTAssertTrue(String(decoding: rich.rtf, as: UTF8.self).contains("{\\listtext\t1.\t}call"))
        XCTAssertTrue(read.string.contains("bread"))
        XCTAssertTrue(read.string.contains("book"))
    }

    // MARK: - Which apps

    func testOnlyAppsThatTakeRichTextGetIt() {
        XCTAssertNotNil(RichListPaste.richText(for: shopping, into: notes))
        XCTAssertNotNil(RichListPaste.richText(for: shopping, into: "com.tinyspeck.slackmacgap"))
        XCTAssertNotNil(RichListPaste.richText(for: shopping, into: "COM.GOOGLE.CHROME"))
        XCTAssertNil(RichListPaste.richText(for: shopping, into: "com.apple.Terminal"))
        XCTAssertNil(RichListPaste.richText(for: shopping, into: "com.googlecode.iterm2"))
        XCTAssertNil(RichListPaste.richText(for: shopping, into: "com.microsoft.VSCode"))
        XCTAssertNil(RichListPaste.richText(for: shopping, into: nil))
        XCTAssertNil(RichListPaste.richText(for: "Bread and chips.", into: notes))
    }

    @MainActor
    func testTheSwitchTurnsItOff() {
        let prefs = AppPreferences.shared
        let saved = prefs.pasteListsAsRichText
        defer { prefs.pasteListsAsRichText = saved }

        prefs.pasteListsAsRichText = true
        XCTAssertNotNil(TranscriptInserter.richText(for: .init(shopping), into: notes, submitting: false))
        prefs.pasteListsAsRichText = false
        XCTAssertNil(TranscriptInserter.richText(for: .init(shopping), into: notes, submitting: false))
    }

    /// The rich forms go into the field with the text, so they are made from the fitted text,
    /// not from the sentence the clipboard keeps.
    @MainActor
    func testTheRichTextIsMadeFromTheFittedText() throws {
        let prefs = AppPreferences.shared
        let saved = prefs.pasteListsAsRichText
        defer { prefs.pasteListsAsRichText = saved }
        prefs.pasteListsAsRichText = true

        let prepared = TranscriptInserter.Prepared(fitted: " we need:\n- bread\n- chips",
                                                   standalone: "We need:\n- bread\n- chips")
        let rich = try XCTUnwrap(TranscriptInserter.richText(for: prepared, into: notes, submitting: false))
        let html = String(decoding: rich.html, as: UTF8.self)
        XCTAssertTrue(html.contains("&nbsp;we need:"), html)
        XCTAssertFalse(html.contains("We need:"), html)
    }

    /// With Return pressed after the paste, the caret would sit in the last item of a real list,
    /// where a rich editor makes a new bullet instead of sending.
    @MainActor
    func testAPasteThatReturnFollowsStaysPlain() {
        let prefs = AppPreferences.shared
        let saved = prefs.pasteListsAsRichText
        defer { prefs.pasteListsAsRichText = saved }
        prefs.pasteListsAsRichText = true

        XCTAssertNil(TranscriptInserter.richText(for: .init(shopping), into: "com.tinyspeck.slackmacgap",
                                                 submitting: true))
        XCTAssertNil(TranscriptInserter.richText(for: .init(shopping), into: nil, submitting: false))
    }

    // MARK: - On the lazy paste item (#162)

    func testTheItemOffersRichTypesBesideThePlainText() throws {
        let rich = try XCTUnwrap(RichListPaste.richText(for: shopping, into: notes))
        var types: [NSPasteboard.PasteboardType] = []
        var plain: String?

        ClipboardUtil.borrowForPaste(shopping, rich: rich, on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.2),
                                     paste: {
            types = pasteboard.pasteboardItems?.first?.types ?? []
            plain = pasteboard.string(forType: .string)
        })
        waitFor(0.4)

        // Read back, the item also lists the text in the forms the system derives from it.
        XCTAssertTrue(Set(types).isSuperset(of: [.rtf, .html, .string]), "\(types)")
        XCTAssertEqual(plain, shopping, "the plain lines keep their \"- \" prefixes")
    }

    /// Left to the system, the UTF-16 text would be derived from the RTF, markers dropped.
    func testEveryPlainTextTypeKeepsTheMarkers() throws {
        let rich = try XCTUnwrap(RichListPaste.richText(for: shopping, into: notes))
        var utf16: String?

        ClipboardUtil.borrowForPaste(shopping, rich: rich, on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.2),
                                     paste: {
            utf16 = pasteboard.data(forType: ClipboardUtil.utf16PlainText)
                .flatMap { String(data: $0, encoding: .utf16) }
        })
        waitFor(0.4)

        XCTAssertEqual(utf16, shopping)
    }

    /// An editor that reads only the HTML has taken the paste all the same, and the clipboard
    /// comes back after that read.
    func testReadingOnlyTheHTMLIsALanding() throws {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        let rich = try XCTUnwrap(RichListPaste.richText(for: shopping, into: notes))
        var outcomes: [ClipboardUtil.PasteOutcome] = []
        var read: Data?

        ClipboardUtil.borrowForPaste(shopping, rich: rich, on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.2),
                                     paste: { read = pasteboard.data(forType: .html) },
                                     outcome: { outcomes.append($0) })
        waitFor(0.4)

        XCTAssertEqual(read, rich.html)
        XCTAssertEqual(outcomes, [.landed])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRTFIsServedOnRequestToo() throws {
        let rich = try XCTUnwrap(RichListPaste.richText(for: shopping, into: notes))
        var read: Data?

        ClipboardUtil.borrowForPaste(shopping, rich: rich, on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.2),
                                     paste: { read = pasteboard.data(forType: .rtf) })
        waitFor(0.4)

        XCTAssertEqual(read, rich.rtf)
    }

    /// Without a list the item is the plain one it always was, with nothing an editor could
    /// take for formatting.
    func testAPlainPasteOffersNoRichTypes() {
        var types: [NSPasteboard.PasteboardType] = []

        ClipboardUtil.borrowForPaste("Bread and chips.", on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.2),
                                     paste: {
            types = pasteboard.types ?? []
            _ = pasteboard.string(forType: .string)
        })
        waitFor(0.4)

        XCTAssertTrue(types.contains(.string))
        XCTAssertFalse(types.contains(.html))
        XCTAssertFalse(types.contains(.rtf))
    }

    /// "Copy to clipboard" on keeps the plain lines, which read the same wherever they go next.
    func testTheKeptCopyIsThePlainText() throws {
        let rich = try XCTUnwrap(RichListPaste.richText(for: shopping, into: notes))

        ClipboardUtil.borrowForPaste(shopping, rich: rich, on: pasteboard,
                                     afterLanding: .transcription, afterMissing: .transcription,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.2),
                                     paste: { _ = pasteboard.data(forType: .html) })
        waitFor(0.4)

        XCTAssertEqual(pasteboard.string(forType: .string), shopping)
        XCTAssertFalse(pasteboard.types?.contains(.html) ?? true)
    }
}
