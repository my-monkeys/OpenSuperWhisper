import KeyboardShortcuts
import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The panel's logic with plain values: which rows it offers, what a key means, where it goes.
/// The panel itself (key status without activation, the paste into the app behind) needs a real
/// desktop and is checked by hand.
final class RecentPickerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func recording(_ text: String, status: RecordingStatus = .completed,
                           secondsAgo: TimeInterval) -> Recording {
        Recording(id: UUID(), timestamp: now.addingTimeInterval(-secondsAgo),
                  fileName: "\(UUID().uuidString).wav", transcription: text, duration: 1,
                  status: status, progress: 1, sourceFileURL: nil)
    }

    // MARK: Rows

    func testRowsAreNumberedNewestFirstAndCappedAtNine() {
        let recordings = (0..<12).map { recording("dictation \($0)", secondsAgo: Double($0) * 60) }
        let rows = RecentPicker.rows(from: recordings.shuffled(), now: now, locale: Locale(identifier: "en"))

        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows.map(\.number), Array(1...9))
        XCTAssertEqual(rows.first?.text, "dictation 0")
        XCTAssertEqual(rows.last?.text, "dictation 8")
    }

    func testRowsSkipTheClipsTheStatusBarMenuSkips() {
        let rows = RecentPicker.rows(from: [
            recording("failed", status: .failed, secondsAgo: 10),
            recording("   ", secondsAgo: 20),
            recording("usable", secondsAgo: 30),
        ], now: now)

        XCTAssertEqual(rows.map(\.text), ["usable"])
    }

    func testNoRecordingsMeansNoRows() {
        XCTAssertTrue(RecentPicker.rows(from: [], now: now).isEmpty)
    }

    func testPreviewCollapsesWhitespaceButInsertionKeepsTheText() {
        let text = "First paragraph.\n\nSecond   paragraph."
        let row = RecentPicker.rows(from: [recording(text, secondsAgo: 5)], now: now).first

        XCTAssertEqual(row?.preview, "First paragraph. Second paragraph.")
        XCTAssertEqual(row?.text, text)
    }

    func testAgeIsShortAndNeverInTheFuture() {
        let english = Locale(identifier: "en")
        let rows = RecentPicker.rows(from: [
            recording("old", secondsAgo: 12 * 60),
            recording("from a clock set back", secondsAgo: -3_600),
        ], now: now, locale: english)

        XCTAssertEqual(rows.first(where: { $0.text == "old" })?.age, "12m ago")
        XCTAssertFalse(try XCTUnwrap(rows.first(where: { $0.text != "old" })).age.hasPrefix("in "))
    }

    // MARK: Keys

    func testDigitKeysOnTheTopRowAndTheKeypad() {
        let topRow: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (index, code) in topRow.enumerated() {
            XCTAssertEqual(RecentPicker.action(forKeyCode: code), .insert(number: index + 1))
        }
        for (index, code) in keypad.enumerated() {
            XCTAssertEqual(RecentPicker.action(forKeyCode: code), .insert(number: index + 1))
        }
    }

    func testZeroAndLettersAreNotActions() {
        XCTAssertNil(RecentPicker.action(forKeyCode: 29), "top row 0")
        XCTAssertNil(RecentPicker.action(forKeyCode: 82), "keypad 0")
        XCTAssertNil(RecentPicker.action(forKeyCode: 0), "a")
    }

    func testNavigationKeys() {
        XCTAssertEqual(RecentPicker.action(forKeyCode: 53), .close)
        XCTAssertEqual(RecentPicker.action(forKeyCode: 125), .moveHighlight(by: 1))
        XCTAssertEqual(RecentPicker.action(forKeyCode: 126), .moveHighlight(by: -1))
        XCTAssertEqual(RecentPicker.action(forKeyCode: 36), .insertHighlighted)
        XCTAssertEqual(RecentPicker.action(forKeyCode: 76), .insertHighlighted, "keypad Enter")
    }

    func testHighlightWrapsAtBothEnds() {
        XCTAssertEqual(RecentPicker.highlight(after: 0, by: 1, rowCount: 3), 1)
        XCTAssertEqual(RecentPicker.highlight(after: 2, by: 1, rowCount: 3), 0)
        XCTAssertEqual(RecentPicker.highlight(after: 0, by: -1, rowCount: 3), 2)
        XCTAssertEqual(RecentPicker.highlight(after: 0, by: 1, rowCount: 0), 0)
    }

    // MARK: Placement

    private let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 400, height: 300)

    func testPlacedBelowTheCaretWhenItFits() {
        let caret = CGRect(x: 100, y: 600, width: 2, height: 18)
        let frame = RecentPicker.frame(size: size, anchor: caret, visible: visible, gap: 6)

        XCTAssertEqual(frame.origin, CGPoint(x: 100, y: 600 - 6 - 300))
        XCTAssertEqual(frame.size, size)
    }

    func testFlipsAboveTheCaretNearTheBottomOfTheScreen() {
        let caret = CGRect(x: 100, y: 120, width: 2, height: 18)
        let frame = RecentPicker.frame(size: size, anchor: caret, visible: visible, gap: 6)

        XCTAssertEqual(frame.minY, caret.maxY + 6)
    }

    func testStaysInsideTheVisibleFrameHorizontally() {
        let nearRightEdge = RecentPicker.frame(size: size, anchor: CGRect(x: 950, y: 600, width: 0, height: 0),
                                               visible: visible)
        XCTAssertEqual(nearRightEdge.maxX, visible.maxX)

        let nearLeftEdge = RecentPicker.frame(size: size, anchor: CGRect(x: -20, y: 600, width: 0, height: 0),
                                              visible: visible)
        XCTAssertEqual(nearLeftEdge.minX, visible.minX)
    }

    func testStaysInsideWhenNeitherSideFits() {
        let tall = CGSize(width: 400, height: 780)
        let frame = RecentPicker.frame(size: tall, anchor: CGRect(x: 10, y: 400, width: 0, height: 0),
                                       visible: visible)
        XCTAssertTrue(visible.contains(frame))
    }

    func testAccessibilityRectIsFlippedAgainstThePrimaryScreen() {
        // AX: top-left origin. A 20 pt tall caret 100 pt from the top of a 900 pt screen.
        let cocoa = RecentPicker.cocoaRect(fromAX: CGRect(x: 50, y: 100, width: 2, height: 20),
                                           primaryScreenMaxY: 900)
        XCTAssertEqual(cocoa, CGRect(x: 50, y: 780, width: 2, height: 20))
    }

    // MARK: Shortcut

    func testShortcutNameAndDefault() {
        XCTAssertEqual(KeyboardShortcuts.Name.pickRecentTranscription.rawValue, "pickRecentTranscription")
        XCTAssertNil(KeyboardShortcuts.Name.pickRecentTranscription.initialShortcut)
    }
}
