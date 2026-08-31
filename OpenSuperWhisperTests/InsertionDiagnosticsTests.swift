import XCTest

@testable import OpenSuperWhisper

/// The line an insertion writes to the log. Its whole job is to be pasted into an issue by
/// somebody who reproduced a fault we cannot, so the shape of it is the deliverable.
final class InsertionDiagnosticsTests: XCTestCase {

    func testTheLineCarriesEveryNumberTheDiagnosisNeeds() {
        let line = TextInserter.insertionLogLine(
            app: "com.microsoft.VSCode", targetLength: 396, caret: 386,
            payload: 107, chunks: 6, pause: 2_000)

        XCTAssertEqual(line,
            "insert app=com.microsoft.VSCode target=396 caret=386 payload=107 "
            + "chunks=6 pause=2000us/gap total=10000us")
    }

    /// An app that will not say how much it holds is the finding, not a hole in the log: pacing
    /// derived from that number cannot work there, and the report came from such an app.
    func testAnUnreadableTargetSaysSoRatherThanReportingZero() {
        let line = TextInserter.insertionLogLine(
            app: "com.example.electron", targetLength: nil, caret: nil,
            payload: 78, chunks: 4, pause: 2_000)

        XCTAssertTrue(line.contains("target=unavailable"))
        XCTAssertTrue(line.contains("caret=unavailable"))
        XCTAssertFalse(line.contains("target=0"))
    }

    /// The caret is what distinguishes the two failure modes reported: text truncated partway,
    /// versus the whole burst landing at a stale position. It can be missing while the length is
    /// readable, so the two are reported independently.
    func testALengthWithoutACaretIsReportable() {
        let line = TextInserter.insertionLogLine(
            app: "dev.warp.Warp-Stable", targetLength: 5_371, caret: nil,
            payload: 40, chunks: 2, pause: 2_000)

        XCTAssertTrue(line.contains("target=5371"))
        XCTAssertTrue(line.contains("caret=unavailable"))
    }

    /// One chunk means no gaps, so the total pause is zero however large the per-gap pause is.
    func testASingleChunkHasNoTotalPause() {
        let line = TextInserter.insertionLogLine(
            app: "x", targetLength: 0, caret: 0, payload: 5, chunks: 1, pause: 2_000)

        XCTAssertTrue(line.contains("chunks=1"))
        XCTAssertTrue(line.contains("total=0us"))
    }

    /// The totals in the log have to match what the insertion actually waits, or the numbers sent
    /// back would describe a build nobody is running.
    func testTheTotalMatchesWhatThePacingActuallyProduces() {
        let payload = String(repeating: "a", count: 107)
        let chunkCount = TextInserter.chunks(of: payload).count
        let pause = TextInserter.chunkPause(forChunkCount: chunkCount)
        let line = TextInserter.insertionLogLine(
            app: "x", targetLength: 396, caret: 386,
            payload: payload.count, chunks: chunkCount, pause: pause)

        XCTAssertTrue(line.contains("chunks=\(chunkCount)"))
        XCTAssertTrue(line.contains("total=\(UInt(pause) * UInt(chunkCount - 1))us"))
    }
}
