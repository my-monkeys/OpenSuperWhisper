import XCTest

@testable import OpenSuperWhisper

/// The line an insertion writes to the log. Its whole job is to be pasted into an issue by
/// somebody who reproduced a fault we cannot, so the shape of it is the deliverable.
final class InsertionDiagnosticsTests: XCTestCase {

    func testTheLineCarriesEveryNumberTheDiagnosisNeeds() {
        let line = TextInserter.insertionLogLine(
            app: "com.microsoft.VSCode", dictatedInto: "com.microsoft.VSCode", rule: "none",
            mechanism: "type", targetLength: 396, caret: 386,
            payload: 107, chunks: 6, pause: 2_000)

        XCTAssertEqual(line,
            "insert via=type app=com.microsoft.VSCode dictated-into=com.microsoft.VSCode "
            + "rule=none target=396 caret=386 payload=107 "
            + "chunks=6 pause=2000us/gap total=10000us")
    }

    /// An app that will not say how much it holds is the finding, not a hole in the log: pacing
    /// derived from that number cannot work there, and the report came from such an app.
    func testAnUnreadableTargetSaysSoRatherThanReportingZero() {
        let line = TextInserter.insertionLogLine(
            app: "com.example.electron", dictatedInto: "com.example.electron", rule: "none",
            mechanism: "type", targetLength: nil, caret: nil,
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
            app: "dev.warp.Warp-Stable", dictatedInto: "dev.warp.Warp-Stable", rule: "none",
            mechanism: "type", targetLength: 5_371, caret: nil,
            payload: 40, chunks: 2, pause: 2_000)

        XCTAssertTrue(line.contains("target=5371"))
        XCTAssertTrue(line.contains("caret=unavailable"))
    }

    /// One chunk means no gaps, so the total pause is zero however large the per-gap pause is.
    func testASingleChunkHasNoTotalPause() {
        let line = TextInserter.insertionLogLine(
            app: "x", dictatedInto: "x", rule: "none", mechanism: "type",
            targetLength: 0, caret: 0, payload: 5, chunks: 1, pause: 2_000)

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
            app: "x", dictatedInto: "x", rule: "none", mechanism: "type",
            targetLength: 396, caret: 386,
            payload: payload.count, chunks: chunkCount, pause: pause)

        XCTAssertTrue(line.contains("chunks=\(chunkCount)"))
        XCTAssertTrue(line.contains("total=\(UInt(pause) * UInt(chunkCount - 1))us"))
    }

    // MARK: - Which app, and which rule

    /// The app receiving the keystrokes and the app the rule came from are different questions,
    /// and they have different answers whenever someone switches app while transcription runs.
    /// A line naming only the first would attribute one app's pace to another and send whoever
    /// reads it into the settings code.
    func testTheReceivingAppAndTheDictatedAppAreBothNamed() {
        let line = TextInserter.insertionLogLine(
            app: "com.apple.Safari", dictatedInto: "com.apple.Terminal", rule: "type@12ms",
            mechanism: "type", targetLength: 396, caret: 386,
            payload: 107, chunks: 6, pause: 12_000)

        XCTAssertTrue(line.contains("app=com.apple.Safari"))
        XCTAssertTrue(line.contains("dictated-into=com.apple.Terminal"))
    }

    /// A rule that matched and a rule that silently did not produce the same pause when the pace
    /// is left at the default, so the line has to say which happened. A typo in a bundle
    /// identifier is the likeliest way to get the second.
    func testAMatchedRuleIsDistinguishableFromNoRule() {
        let matched = TextInserter.ruleDescription(
            AppInsertionRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal",
                             mode: .type, typingPaceMilliseconds: 12))
        let matchedAtGlobalPace = TextInserter.ruleDescription(
            AppInsertionRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal",
                             mode: .type))
        let pasting = TextInserter.ruleDescription(
            AppInsertionRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal",
                             mode: .paste))

        XCTAssertEqual(matched, "type@12ms")
        XCTAssertEqual(matchedAtGlobalPace, "type")
        XCTAssertEqual(pasting, "paste")
        XCTAssertEqual(TextInserter.ruleDescription(nil), "none")
    }

    /// Pasting logs too. It has nothing to pace, but a report has to be able to say which of the
    /// two mechanisms ran, and a paste that logged nothing read exactly like an insertion that
    /// never happened.
    func testPastingIsReportedAsItsOwnMechanism() {
        let line = TextInserter.insertionLogLine(
            app: "com.apple.Terminal", dictatedInto: "com.apple.Terminal", rule: "paste",
            mechanism: "paste", targetLength: 396, caret: nil,
            payload: 107, chunks: 1, pause: 0)

        XCTAssertTrue(line.contains("via=paste"))
        XCTAssertTrue(line.contains("total=0us"))
    }

    /// A clip recorded before the app was known still logs, rather than dropping the line.
    func testAnUnknownDictatedAppSaysSo() {
        let line = TextInserter.insertionLogLine(
            app: "com.apple.Terminal", dictatedInto: nil, rule: "none", mechanism: "type",
            targetLength: nil, caret: nil, payload: 10, chunks: 1, pause: 0)

        XCTAssertTrue(line.contains("dictated-into=unknown"))
    }
}
