import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Covers what the status bar's "Recent" submenu offers and how it labels it. The rows are the
/// same "worth re-inserting" set the paste-last shortcut uses, so a failed or in-flight clip
/// must never reach the menu: choosing one would paste a retry placeholder into the user's
/// document.
final class RecentTranscriptsTests: XCTestCase {

    private func makeRecording(_ transcription: String,
                               status: RecordingStatus = .completed,
                               secondsAgo: TimeInterval) -> Recording {
        Recording(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000_000 - secondsAgo),
            fileName: "\(UUID().uuidString).wav",
            transcription: transcription,
            duration: 1,
            status: status,
            progress: 1,
            sourceFileURL: nil
        )
    }

    // MARK: - Picking

    func testOrdersNewestFirstRegardlessOfArrayOrder() {
        let picked = RecentTranscripts.pick(from: [
            makeRecording("middle", secondsAgo: 60),
            makeRecording("newest", secondsAgo: 0),
            makeRecording("oldest", secondsAgo: 600),
        ], limit: 5)

        XCTAssertEqual(picked.map(\.transcription), ["newest", "middle", "oldest"])
    }

    func testHonoursTheLimit() {
        let many = (0..<20).map { makeRecording("clip \($0)", secondsAgo: TimeInterval($0)) }
        XCTAssertEqual(RecentTranscripts.pick(from: many, limit: 6).count, 6)
    }

    func testSkipsClipsThatAreNotCompleted() {
        let picked = RecentTranscripts.pick(from: [
            makeRecording("still going", status: .transcribing, secondsAgo: 0),
            makeRecording("failed one", status: .failed, secondsAgo: 1),
            makeRecording("usable", secondsAgo: 2),
        ], limit: 5)

        XCTAssertEqual(picked.map(\.transcription), ["usable"])
    }

    func testSkipsEmptyAndWhitespaceOnlyTranscriptions() {
        let picked = RecentTranscripts.pick(from: [
            makeRecording("", secondsAgo: 0),
            makeRecording("   \n  ", secondsAgo: 1),
            makeRecording("real text", secondsAgo: 2),
        ], limit: 5)

        XCTAssertEqual(picked.map(\.transcription), ["real text"])
    }

    func testNothingUsableYieldsNoRows() {
        XCTAssertTrue(RecentTranscripts.pick(from: [], limit: 5).isEmpty)
    }

    /// The shortcut and the menu must agree on which clip is "the last one", or pressing the
    /// shortcut and picking the top row would insert different text.
    func testAgreesWithThePasteLastShortcut() {
        let recordings = [
            makeRecording("failed", status: .failed, secondsAgo: 0),
            makeRecording("newest good", secondsAgo: 5),
            makeRecording("older", secondsAgo: 50),
        ]

        XCTAssertEqual(RecentTranscripts.pick(from: recordings, limit: 1).first?.transcription,
                       PasteLastTranscript.pick(from: recordings))
    }

    // MARK: - Labelling

    func testShortTranscriptionIsUsedAsIs() {
        XCTAssertEqual(RecentTranscripts.menuTitle(for: "Hello there"), "Hello there")
    }

    /// A dictation spanning paragraphs would otherwise render as a row of blanks.
    func testNewlinesAndRunsOfSpacesCollapse() {
        XCTAssertEqual(RecentTranscripts.menuTitle(for: "first line\n\nsecond    line"),
                       "first line second line")
    }

    func testLongTranscriptionIsTruncatedWithAnEllipsis() {
        let title = RecentTranscripts.menuTitle(for: String(repeating: "a", count: 200), limit: 20)

        XCTAssertEqual(title.count, 21, "20 characters plus the ellipsis")
        XCTAssertTrue(title.hasSuffix("…"))
    }

    /// Truncating mid-space would leave "word …" hanging.
    func testTruncationDoesNotLeaveATrailingSpace() {
        let title = RecentTranscripts.menuTitle(for: "abcdefghij klmnopqrst", limit: 11)
        XCTAssertEqual(title, "abcdefghij…")
    }

    func testEmptyTranscriptionYieldsEmptyTitle() {
        XCTAssertEqual(RecentTranscripts.menuTitle(for: "   \n "), "")
    }
}
