import XCTest
@testable import OpenSuperWhisper

/// "Cursor" mode anchors the bubble to whatever the focused text element reports about its caret.
/// Chrome answers with an empty rect nowhere near the field (#143), so since #144 such a caret is
/// discarded for the field. Terminal.app answers the same way, and its field is the whole window,
/// which put the bubble at the window's corner (#155), as did Ghostty, which refuses to place
/// anything. These replay what each app reports, see `CaretGeometryFixtures`, and pin down where
/// the bubble goes.
final class CaretAnchorRectTests: XCTestCase {

    /// The Chrome and TextEdit recordings were made on a second 2560 x 1440 display, right of a
    /// primary one of the same size.
    private static let twoDisplays = [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                      CGRect(x: 2560, y: 0, width: 2560, height: 1440)]

    private func choose(_ element: RecordedTextElement,
                        displays: [CGRect] = twoDisplays) -> CaretAnchor.Choice? {
        CaretAnchor.choose(selection: element.selection, in: element, displays: displays)
    }

    // MARK: Chrome stays on the field (#144)

    func testChromeFieldsAnchorToTheFieldWhenNeitherCaretNorCharacterHasHeight() {
        for element in [CaretGeometryFixtures.chromeOmnibox(), CaretGeometryFixtures.chromeInput(),
                        CaretGeometryFixtures.chromeTextarea(), CaretGeometryFixtures.chromeContentEditable()] {
            let choice = choose(element)
            XCTAssertEqual(choice?.source, .field, element.name)
            XCTAssertEqual(choice?.rect, element.frame, element.name)
        }
    }

    /// The same answers from a field the size of its window: its corner is the top-left of the
    /// screen, nowhere near the typing, so the bubble follows the mouse.
    func testAWindowSizedFieldFollowsTheMouse() {
        XCTAssertNil(choose(CaretGeometryFixtures.windowSizedField(),
                            displays: CaretGeometryFixtures.diaDisplays))
    }

    /// A field of an input's size, but above the top of the screen: placed there, the bubble was
    /// pushed back against the top-left of the screen.
    func testAFieldOffEveryDisplayFollowsTheMouse() {
        XCTAssertNil(choose(CaretGeometryFixtures.diaOffscreenField(),
                            displays: CaretGeometryFixtures.diaDisplays))
    }

    /// The same field on the display is a field like Chrome's, and the bubble goes there.
    func testTheSameFieldOnTheDisplayIsUsed() {
        let onScreen = RecordedTextElement("Dia, field on the screen",
                                           selection: CFRange(location: 0, length: 0),
                                           bounds: ["0+0": CGRect(x: 0, y: 1117, width: 0, height: 0)],
                                           frame: CGRect(x: 210, y: 176, width: 331, height: 22))
        XCTAssertEqual(choose(onScreen, displays: CaretGeometryFixtures.diaDisplays)?.source, .field)
    }

    // MARK: A real caret is used as reported

    /// TextEdit reports its caret above the text view's own frame. It is still the right place,
    /// and an app with a real caret is asked nothing more.
    func testTextEditCaretIsUsedWithASingleQuestion() {
        let textEdit = CaretGeometryFixtures.textEdit()
        let choice = choose(textEdit)
        XCTAssertEqual(choice, .init(rect: CGRect(x: 2966.35, y: 88, width: 0, height: 14), source: .caret))
        XCTAssertEqual(textEdit.asked, ["bounds(3+0)"])
    }

    // MARK: Terminals (#155)

    /// The character before the caret is on the prompt line; the bubble anchors where it ends,
    /// which is where the caret is.
    func testTerminalAnchorsToTheEndOfTheCharacterBeforeTheCaret() {
        let terminal = CaretGeometryFixtures.terminal()
        let choice = choose(terminal)
        XCTAssertEqual(choice, .init(rect: CGRect(x: 254, y: 523, width: 0, height: 15), source: .characterBefore))
        XCTAssertEqual(terminal.asked, ["bounds(5231+0)", "bounds(5230+1)", "frame"])
    }

    /// Ghostty refuses every range, and its caret sits at offset 0 when nothing is selected. Its
    /// surface's top-left corner is where #144 put the bubble; it follows the mouse again, as it
    /// did before, and neither the first character of the scrollback nor the frame is asked about.
    func testGhosttyFollowsTheMouseWithoutAskingAnythingElse() {
        let ghostty = CaretGeometryFixtures.ghostty()
        XCTAssertNil(choose(ghostty))
        XCTAssertEqual(ghostty.asked, ["bounds(0+0)"])
    }

    /// With the caret at the start of a line, the character before is the newline ending the
    /// line above. Accepted: the bubble goes to the end of that line, one line off the prompt.
    func testCaretAfterANewlineAnchorsToTheEndOfTheLineAbove() {
        let element = RecordedTextElement("Terminal.app, caret at column 0",
                                          selection: CFRange(location: 5240, length: 0),
                                          bounds: ["5240+0": CGRect(x: 0, y: 1440, width: 0, height: 0),
                                                   "5239+1": CGRect(x: 254, y: 523, width: 7, height: 15)],
                                          frame: CGRect(x: 120, y: 200, width: 732, height: 456))
        XCTAssertEqual(choose(element), .init(rect: CGRect(x: 261, y: 523, width: 0, height: 15), source: .characterBefore))
    }

    /// A selection whose bounds have no height anchors where the selection starts, at the end of
    /// the character before it.
    func testSelectionWithoutBoundsAnchorsToWhereItStarts() {
        let element = RecordedTextElement("Terminal.app, mouse selection",
                                          selection: CFRange(location: 5226, length: 4),
                                          bounds: ["5226+4": .zero,
                                                   "5225+1": CGRect(x: 219, y: 523, width: 7, height: 15)],
                                          frame: CGRect(x: 120, y: 200, width: 732, height: 456))
        XCTAssertEqual(choose(element), .init(rect: CGRect(x: 226, y: 523, width: 0, height: 15), source: .characterBefore))
        XCTAssertEqual(element.asked, ["bounds(5226+4)", "bounds(5225+1)", "frame"])
    }

    // MARK: Edge cases

    /// Chrome's text-marker query answers with the entire editor (#143). A "character" that
    /// covers its field is the field, and its trailing edge would sit past the field's far side.
    func testCharacterCoveringTheFieldIsNotUsed() {
        let field = CGRect(x: 4061, y: 517, width: 402, height: 82)
        let element = RecordedTextElement("whole-editor character",
                                          selection: CFRange(location: 8, length: 0),
                                          bounds: ["8+0": .zero, "7+1": field.insetBy(dx: -1, dy: -1)],
                                          frame: field)
        XCTAssertEqual(choose(element), .init(rect: field, source: .field))
    }

    /// A character with height can be as misplaced as Chrome's caret (#143): here at the
    /// primary display's bottom edge, nowhere near the field. The field is used, as before.
    func testCharacterOutsideTheFieldIsNotUsed() {
        let field = CGRect(x: 4061, y: 517, width: 402, height: 82)
        let element = RecordedTextElement("misplaced character",
                                          selection: CFRange(location: 8, length: 0),
                                          bounds: ["8+0": .zero, "7+1": CGRect(x: 0, y: 1440, width: 7, height: 15)],
                                          frame: field)
        XCTAssertEqual(choose(element), .init(rect: field, source: .field))
    }

    /// Text can be reported just outside its view's frame, as TextEdit's caret is: within a line
    /// of the field, the character is still believed.
    func testCharacterJustOutsideTheFieldIsUsed() {
        let element = RecordedTextElement("character above its frame",
                                          selection: CFRange(location: 3, length: 0),
                                          bounds: ["3+0": .zero, "2+1": CGRect(x: 2960, y: 88, width: 6, height: 14)],
                                          frame: CGRect(x: 2936, y: 102, width: 586, height: 382))
        XCTAssertEqual(choose(element), .init(rect: CGRect(x: 2966, y: 88, width: 0, height: 14), source: .characterBefore))
    }

    /// Some text views refuse a zero-length range but place a character. The character is used;
    /// had it been misplaced, the bubble would follow the mouse rather than the field, since the
    /// element never answered for its caret.
    func testRefusedCaretFallsBackToTheCharacterBeforeThenTheMouse() {
        let field = CGRect(x: 300, y: 380, width: 400, height: 200)
        let placed = RecordedTextElement("refused caret", selection: CFRange(location: 2, length: 0),
                                         bounds: ["1+1": CGRect(x: 300, y: 400, width: 8, height: 18)],
                                         frame: field)
        XCTAssertEqual(choose(placed), .init(rect: CGRect(x: 308, y: 400, width: 0, height: 18), source: .characterBefore))
        let misplaced = RecordedTextElement("refused caret, misplaced character",
                                            selection: CFRange(location: 2, length: 0),
                                            bounds: ["1+1": CGRect(x: 0, y: 1440, width: 8, height: 18)],
                                            frame: field)
        XCTAssertNil(choose(misplaced))
    }

    func testCharacterBeforeIsUsedWhenTheFieldFrameIsUnknown() {
        let element = RecordedTextElement("no frame",
                                          selection: CFRange(location: 2, length: 0),
                                          bounds: ["1+1": CGRect(x: 300, y: 400, width: 8, height: 18)],
                                          frame: nil)
        XCTAssertEqual(choose(element), .init(rect: CGRect(x: 308, y: 400, width: 0, height: 18), source: .characterBefore))
    }

    func testCaretIsUsedWhenTheElementFrameIsUnknown() {
        let caret = CGRect(x: 300, y: 400, width: 0, height: 18)
        let element = RecordedTextElement("caret only", selection: CFRange(location: 1, length: 0),
                                          bounds: ["1+0": caret], frame: nil)
        XCTAssertEqual(choose(element), .init(rect: caret, source: .caret))
    }

    func testNothingUsableGivesNothing() {
        let empty = RecordedTextElement("empty answers", selection: CFRange(location: 4, length: 0),
                                        bounds: ["4+0": .zero, "3+1": .zero], frame: .zero)
        XCTAssertNil(choose(empty))
        let refused = RecordedTextElement("refused", selection: CFRange(location: 4, length: 0),
                                          bounds: [:], frame: nil)
        XCTAssertNil(choose(refused))
    }
}
