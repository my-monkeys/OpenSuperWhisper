import XCTest
@testable import OpenSuperWhisper

/// "Cursor" mode anchors the bubble to whatever the focused text element reports as its caret.
/// Chrome's address bar answers that query with an empty rect at the bottom-left of the primary
/// display, which put the bubble in the corner of a different screen. These pin down when the
/// caret is believed and when the field itself is used instead. Rects are in AX (top-left
/// origin) coordinates, taken from the apps.
final class CaretAnchorRectTests: XCTestCase {

    /// The Chrome omnibox on a second display, as measured.
    let omnibox = CGRect(x: 4024, y: 77, width: 1203, height: 24)

    func testChromeOmniboxEmptyCaretFallsBackToTheField() {
        let reported = CGRect(x: 0, y: 1440, width: 0, height: 0)
        XCTAssertEqual(FocusUtils.caretAnchorRect(caret: reported, element: omnibox), omnibox)
    }

    func testCaretWithHeightIsUsed() {
        let caret = CGRect(x: 4300, y: 80, width: 0, height: 18)
        XCTAssertEqual(FocusUtils.caretAnchorRect(caret: caret, element: omnibox), caret)
    }

    /// TextEdit reports its caret above the text view's own frame. It is still the right place.
    func testCaretOutsideItsElementIsStillUsed() {
        let textView = CGRect(x: 2936, y: 102, width: 586, height: 382)
        let caret = CGRect(x: 2966.35, y: 88, width: 0, height: 14)
        XCTAssertEqual(FocusUtils.caretAnchorRect(caret: caret, element: textView), caret)
    }

    func testCaretIsUsedWhenTheElementFrameIsUnknown() {
        let caret = CGRect(x: 300, y: 400, width: 0, height: 18)
        XCTAssertEqual(FocusUtils.caretAnchorRect(caret: caret, element: nil), caret)
    }

    func testNoCaretUsesTheElement() {
        XCTAssertEqual(FocusUtils.caretAnchorRect(caret: nil, element: omnibox), omnibox)
    }

    func testNothingUsableGivesNothing() {
        XCTAssertNil(FocusUtils.caretAnchorRect(caret: .zero, element: nil))
        XCTAssertNil(FocusUtils.caretAnchorRect(caret: nil, element: .zero))
    }
}
