import AppKit
import XCTest

@testable import OpenSuperWhisper

/// Covers the pasteboard snapshot/restore behind paste mode with "Copy to clipboard" off (#44),
/// where the clipboard is only borrowed as the ⌘V vehicle and must be given back. Runs against a
/// private named pasteboard so the developer's real clipboard is never touched.
final class ClipboardRestoreTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenSuperWhisperTests." + UUID().uuidString))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    // MARK: - snapshot / restore

    func testSnapshotRestoreRoundtripsString() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        let snapshot = ClipboardUtil.snapshot(of: pasteboard)

        ClipboardUtil.copyToClipboard("transcription", to: pasteboard)
        ClipboardUtil.restore(snapshot, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testSnapshotRestorePreservesEveryTypeOfAnItem() {
        // An item carrying several representations (e.g. rich text copied from a browser)
        // must come back whole, not just its plain-string face.
        let blobType = NSPasteboard.PasteboardType("com.example.blob")
        let item = NSPasteboardItem()
        item.setString("styled", forType: .string)
        item.setData(Data([1, 2, 3]), forType: blobType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let snapshot = ClipboardUtil.snapshot(of: pasteboard)

        ClipboardUtil.copyToClipboard("transcription", to: pasteboard)
        ClipboardUtil.restore(snapshot, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "styled")
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: blobType), Data([1, 2, 3]))
    }

    func testRestoreOfEmptySnapshotLeavesPasteboardEmpty() {
        pasteboard.clearContents()
        let empty = ClipboardUtil.snapshot(of: pasteboard)

        ClipboardUtil.copyToClipboard("transcription", to: pasteboard)
        ClipboardUtil.restore(empty, to: pasteboard)

        XCTAssertNil(pasteboard.string(forType: .string))
    }

    // MARK: - borrowForPaste

    func testBorrowForPasteHasTextOnPasteboardDuringPaste() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)

        var textDuringPaste: String?
        ClipboardUtil.borrowForPaste("transcription", on: pasteboard, restoreAfter: 0.05) {
            textDuringPaste = pasteboard.string(forType: .string)
        }

        XCTAssertEqual(textDuringPaste, "transcription")
    }

    func testBorrowForPasteRestoresPreviousContentsAfterDelay() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard, restoreAfter: 0.05) {}

        let restoreWindowElapsed = expectation(description: "restore window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restoreWindowElapsed.fulfill() }
        wait(for: [restoreWindowElapsed], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testBorrowForPasteSkipsRestoreWhenSomethingElseWroteMeanwhile() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard, restoreAfter: 0.05) {}
        ClipboardUtil.copyToClipboard("user copy in between", to: pasteboard)

        let restoreWindowElapsed = expectation(description: "restore window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restoreWindowElapsed.fulfill() }
        wait(for: [restoreWindowElapsed], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy in between")
    }
}
