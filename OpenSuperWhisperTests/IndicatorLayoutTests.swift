import XCTest

@testable import OpenSuperWhisper

/// The bubble's contents are persisted as JSON and rebuilt from the old switches on upgrade,
/// so both paths are pinned: a bad decode would blank someone's indicator.
final class IndicatorLayoutTests: XCTestCase {

    func testRoundTripsThroughJSON() {
        var layout = IndicatorLayout.default
        layout.setVisible(true, for: .stopButton)
        layout.waveformHeight = 22
        XCTAssertEqual(IndicatorLayout.load(from: layout.json), layout)
    }

    func testBadOrEmptyStoredValueFallsBackToTheDefault() {
        XCTAssertEqual(IndicatorLayout.load(from: ""), .default)
        XCTAssertEqual(IndicatorLayout.load(from: "not json"), .default)
    }

    /// A stored order from an older build won't list every element. The missing ones have to
    /// reappear, or the editor simply can't show them.
    func testStoredOrderIsRepaired() {
        let partial = #"{"order":["label","label"],"hidden":[],"waveformHeight":30}"#
        let loaded = IndicatorLayout.load(from: partial)
        XCTAssertEqual(loaded.order.first, .label)
        XCTAssertEqual(Set(loaded.order), Set(IndicatorElement.allCases))
        XCTAssertEqual(loaded.order.count, IndicatorElement.allCases.count, "no duplicates")
    }

    /// Switching an element off must not lose its position: switching it back on returns it
    /// where it was rather than appending it to the end.
    func testHidingKeepsPositionForWhenItComesBack() {
        var layout = IndicatorLayout(order: [.waveform, .label, .dot, .stopButton, .cancelButton],
                                     hidden: [.stopButton, .cancelButton], waveformHeight: 30)
        layout.setVisible(false, for: .label)
        XCTAssertEqual(layout.elements, [.waveform, .dot])
        layout.setVisible(true, for: .label)
        XCTAssertEqual(layout.elements, [.waveform, .label, .dot])
    }

    func testMoveReordersIncludingHiddenElements() {
        var layout = IndicatorLayout(order: [.waveform, .label, .dot, .stopButton, .cancelButton],
                                     hidden: [.dot], waveformHeight: 30)
        layout.move(.dot, toPointerY: 0, rows: Self.rows)
        XCTAssertEqual(layout.order.first, .dot, "a hidden element can still be repositioned")
        layout.setVisible(true, for: .dot)
        XCTAssertEqual(layout.elements.first, .dot)
    }

    /// Buttons render at the trailing edge whatever the order says, so a click target can't
    /// end up between the waveform and the text.
    func testButtonsAlwaysSplitToTheTrailingEdge() {
        let layout = IndicatorLayout(order: [.stopButton, .waveform, .cancelButton, .label],
                                     hidden: [], waveformHeight: 30)
        XCTAssertEqual(layout.leading, [.waveform, .label])
        XCTAssertEqual(layout.trailing, [.stopButton, .cancelButton])
    }

    /// Reordering the buttons between themselves does take effect, which is the part that
    /// looked broken when the whole row was draggable.
    func testButtonsKeepTheirRelativeOrder() {
        var layout = IndicatorLayout(order: [.waveform, .stopButton, .cancelButton],
                                     hidden: [], waveformHeight: 30)
        layout.move(.cancelButton, toPointerY: 0, rows: Self.rows)
        XCTAssertEqual(layout.trailing, [.cancelButton, .stopButton])
    }

    /// Rows 40 high, 6 apart, in the order the list draws them.
    private static let rows: [IndicatorElement: CGRect] = [
        .waveform: CGRect(x: 0, y: 0, width: 300, height: 40),
        .label: CGRect(x: 0, y: 46, width: 300, height: 40),
        .dot: CGRect(x: 0, y: 92, width: 300, height: 40),
        .stopButton: CGRect(x: 0, y: 138, width: 300, height: 40),
        .cancelButton: CGRect(x: 0, y: 184, width: 300, height: 40),
    ]

    func testDraggingDownPastARowsMiddleMovesAfterIt() {
        var layout = IndicatorLayout(order: [.waveform, .label, .dot, .stopButton, .cancelButton],
                                     hidden: [], waveformHeight: 30)
        layout.move(.waveform, toPointerY: 70, rows: Self.rows)
        XCTAssertEqual(layout.order, [.label, .waveform, .dot, .stopButton, .cancelButton])
        layout.move(.waveform, toPointerY: 500, rows: Self.rows)
        XCTAssertEqual(layout.order.last, .waveform, "dragged past the end of the list")
    }

    func testPointerBeforeTheNextRowsMiddleLeavesTheOrderAlone() {
        var layout = IndicatorLayout(order: [.waveform, .label, .dot, .stopButton, .cancelButton],
                                     hidden: [], waveformHeight: 30)
        layout.move(.label, toPointerY: 80, rows: Self.rows)
        XCTAssertEqual(layout.order, [.waveform, .label, .dot, .stopButton, .cancelButton])
        layout.move(.label, toPointerY: -30, rows: Self.rows)
        XCTAssertEqual(layout.order.first, .label, "dragged above the list")
    }

    func testRowsOutsideTheMapAreNotCounted() {
        var layout = IndicatorLayout(order: [.waveform, .label, .dot, .stopButton, .cancelButton],
                                     hidden: [], waveformHeight: 30)
        layout.move(.waveform, toPointerY: 500, rows: [.waveform: Self.rows[.waveform]!, .label: Self.rows[.label]!])
        XCTAssertEqual(layout.order, [.label, .waveform, .dot, .stopButton, .cancelButton])
    }

    func testMigrationReproducesTheOldSettings() {
        let off = IndicatorLayout.migrated(meterMode: "off", showStop: false, showCancel: false)
        XCTAssertEqual(off.elements, [.dot, .label, .liveText])

        let replaces = IndicatorLayout.migrated(meterMode: "replacesDot", showStop: false, showCancel: false)
        XCTAssertEqual(replaces.elements, [.waveform, .label, .liveText])

        let beside = IndicatorLayout.migrated(meterMode: "besideLabel", showStop: true, showCancel: true)
        XCTAssertEqual(beside.elements, [.dot, .label, .waveform, .stopButton, .cancelButton, .liveText])
    }

    /// A layout stored before the live text became an element lists none of it. It must come
    /// back with the live text shown, as it always was, and not reorderable.
    func testLayoutStoredBeforeLiveTextShowsIt() {
        let old = #"{"order":["waveform","label","dot","stopButton","cancelButton"],"hidden":["dot"],"waveformHeight":30}"#
        let loaded = IndicatorLayout.load(from: old)
        XCTAssertTrue(loaded.isVisible(.liveText))
        XCTAssertEqual(loaded.order.last, .liveText)
        XCTAssertEqual(loaded.leading, [.waveform, .label])
        XCTAssertFalse(loaded.trailing.contains(.liveText))
    }

    func testHidingLiveTextRemovesItWithoutTouchingTheRow() {
        var layout = IndicatorLayout.default
        layout.setVisible(false, for: .liveText)
        XCTAssertFalse(layout.contains(.liveText))
        XCTAssertEqual(layout.leading, IndicatorLayout.default.leading)
    }
}
