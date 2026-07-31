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

    // MARK: - Overlapping borrows (#69 review)

    func testOverlappingBorrowsRestoreTheOriginalContents() {
        // Dictation borrows the clipboard, and before its restore fires the user re-pastes
        // (or a second dictation lands). The second borrow must NOT snapshot the first borrow's
        // transcription — it inherits the original snapshot, and the one surviving restore
        // brings back the user's contents.
        ClipboardUtil.copyToClipboard("original", to: pasteboard)

        ClipboardUtil.borrowForPaste("transcription A", on: pasteboard, restoreAfter: 0.05) {}
        ClipboardUtil.borrowForPaste("transcription B", on: pasteboard, restoreAfter: 0.05) {}

        let restoreWindowElapsed = expectation(description: "restore window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restoreWindowElapsed.fulfill() }
        wait(for: [restoreWindowElapsed], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "original",
                       "the second borrow must not end up restoring the first borrow's text")
    }

    func testManyOverlappingBorrowsStillRestoreTheOriginal() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)

        for n in 1...4 {
            ClipboardUtil.borrowForPaste("transcription \(n)", on: pasteboard, restoreAfter: 0.05) {}
        }

        let restoreWindowElapsed = expectation(description: "restore window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restoreWindowElapsed.fulfill() }
        wait(for: [restoreWindowElapsed], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testUserCopyAfterOverlappingBorrowsStillWins() {
        // Newer content beats our restore even when borrows have coalesced.
        ClipboardUtil.copyToClipboard("original", to: pasteboard)

        ClipboardUtil.borrowForPaste("transcription A", on: pasteboard, restoreAfter: 0.05) {}
        ClipboardUtil.borrowForPaste("transcription B", on: pasteboard, restoreAfter: 0.05) {}
        ClipboardUtil.copyToClipboard("user copy in between", to: pasteboard)

        let restoreWindowElapsed = expectation(description: "restore window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restoreWindowElapsed.fulfill() }
        wait(for: [restoreWindowElapsed], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy in between")
    }

    func testSequentialBorrowsDoNotInheritAStaleSnapshot() {
        // Once a borrow's restore has fired, the next borrow is a fresh cycle: it must snapshot
        // whatever is on the pasteboard NOW, not resurrect the coalescing state of the last one.
        ClipboardUtil.copyToClipboard("first original", to: pasteboard)
        ClipboardUtil.borrowForPaste("transcription A", on: pasteboard, restoreAfter: 0.05) {}

        let firstRestoreDone = expectation(description: "first restore done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { firstRestoreDone.fulfill() }
        wait(for: [firstRestoreDone], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "first original")

        ClipboardUtil.copyToClipboard("second original", to: pasteboard)
        ClipboardUtil.borrowForPaste("transcription B", on: pasteboard, restoreAfter: 0.05) {}

        let secondRestoreDone = expectation(description: "second restore done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { secondRestoreDone.fulfill() }
        wait(for: [secondRestoreDone], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "second original")
    }

    func testBorrowsOnDistinctPasteboardsDoNotShareSnapshots() {
        // Coalescing is per pasteboard: a pending borrow on one must not donate its snapshot
        // to a borrow on another.
        let other = NSPasteboard(name: NSPasteboard.Name("OpenSuperWhisperTests." + UUID().uuidString))
        defer { other.releaseGlobally() }
        ClipboardUtil.copyToClipboard("original A", to: pasteboard)
        ClipboardUtil.copyToClipboard("original B", to: other)

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard, restoreAfter: 0.05) {}
        ClipboardUtil.borrowForPaste("transcription", on: other, restoreAfter: 0.05) {}

        let restoreWindowElapsed = expectation(description: "restore window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restoreWindowElapsed.fulfill() }
        wait(for: [restoreWindowElapsed], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "original A")
        XCTAssertEqual(other.string(forType: .string), "original B")
    }
}
