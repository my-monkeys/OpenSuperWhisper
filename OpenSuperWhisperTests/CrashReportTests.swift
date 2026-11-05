import XCTest

@testable import OpenSuperWhisper

final class CrashReportModeTests: XCTestCase {

    func testRawValuesAreStable() {
        XCTAssertEqual(CrashReportMode.ask.rawValue, "ask")
        XCTAssertEqual(CrashReportMode.auto.rawValue, "auto")
        XCTAssertEqual(CrashReportMode.off.rawValue, "off")
    }

    func testAFreshInstallAsks() {
        XCTAssertEqual(CrashReportMode.default, .ask)
    }

    /// An absent or unreadable value reads as the default rather than failing, so a key written by
    /// a newer build never leaves the setting in no state at all.
    func testResolveFallsBackToTheDefault() {
        XCTAssertEqual(CrashReportMode.resolve("auto"), .auto)
        XCTAssertEqual(CrashReportMode.resolve(nil), .ask)
        XCTAssertEqual(CrashReportMode.resolve("something-newer"), .ask)
    }

    func testTheModeDecidesWhatHappensToABatch() {
        XCTAssertEqual(CrashReporter.action(for: .off), .discard)
        XCTAssertEqual(CrashReporter.action(for: .auto), .send)
        XCTAssertEqual(CrashReporter.action(for: .ask), .ask)
    }
}

final class CrashReportTests: XCTestCase {

    private func draft(frames: [String], cause: String = "EXC_BAD_ACCESS (SIGSEGV)") -> CrashReportDraft {
        CrashReportDraft(kind: .crash, cause: cause, frames: frames,
                         appVersion: "0.14.0 (63)", osVersion: "26.2")
    }

    // MARK: - Message

    func testTheMessageLeadsWithTheCauseThenNumbersTheFrames() {
        let message = CrashReport.message(for: draft(frames: ["A 0x01", "B 0x02", "C 0x03"]),
                                          frameLimit: 3)

        XCTAssertEqual(message, "crash: EXC_BAD_ACCESS (SIGSEGV)\n#0 A 0x01\n#1 B 0x02\n#2 C 0x03")
    }

    /// The deepest frames go first: the fault is at the top of the stack.
    func testTheFrameLimitKeepsTheTopOfTheStack() {
        let message = CrashReport.message(for: draft(frames: ["top 0x01", "mid 0x02", "deep 0x03"]),
                                          frameLimit: 1)

        XCTAssertEqual(message, "crash: EXC_BAD_ACCESS (SIGSEGV)\n#0 top 0x01")
    }

    // MARK: - Submission

    func testAnOrdinaryStackSendsEveryFrameAnonymously() {
        let frames = (0..<20).map { "OpenSuperWhisper 0x\($0)" }
        let submission = CrashReport.submission(for: draft(frames: frames))

        XCTAssertEqual(submission.kind, .crash)
        XCTAssertEqual(submission.email, "")
        XCTAssertEqual(submission.details, "OpenSuperWhisper 0.14.0 (63) · macOS 26.2")
        XCTAssertEqual(submission.context, "app · crash · OpenSuperWhisper 0.14.0 (63) · macOS 26.2")
        XCTAssertTrue(submission.message.contains("#19 OpenSuperWhisper 0x19"))
        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
    }

    /// A stack far past the endpoint's byte limit still sends: frames are dropped from the bottom
    /// until it fits, and the top frame, where the fault is, always survives.
    func testAnOversizedStackIsTrimmedToFitAndKeepsItsTop() {
        let frames = (0..<400).map { "VeryLongBinaryNameThatPadsEachFrameNicely_\($0) 0x000000010abcdef0" }
        let submission = CrashReport.submission(for: draft(frames: frames))

        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
        XCTAssertTrue(submission.message.contains("#0 VeryLongBinaryNameThatPadsEachFrameNicely_0 "))
        XCTAssertFalse(submission.message.contains("#399 "))
    }

    func testAnOverlongCauseIsTruncated() {
        let message = CrashReport.message(for: draft(frames: [], cause: String(repeating: "x", count: 500)),
                                          frameLimit: 0)

        XCTAssertTrue(message.hasPrefix("crash: "))
        XCTAssertLessThanOrEqual(message.count, "crash: ".count + 200)
    }
}

final class CallStackTreeTests: XCTestCase {

    private let appUUID = "70B89F27-1634-3580-A695-57CDB41D7743"
    private let dyldUUID = "77A62F2E-8212-30F3-84C1-E8497440ACF8"

    /// The shape MetricKit documents: a `callStackTree` wrapper, one stack per thread, nested sub-frames.
    private func tree(attributedFrames: String) -> Data {
        Data("""
        {"callStackTree": {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": false, "callStackRootFrames": [
            {"binaryName": "Other", "address": 1, "offsetIntoBinaryTextSegment": 1}]},
          {"threadAttributed": true, "callStackRootFrames": [\(attributedFrames)]}
        ]}}
        """.utf8)
    }

    private var appDyldApp: String {
        """
        {"binaryName": "OpenSuperWhisper", "binaryUUID": "\(appUUID)", "address": 4365854028,
         "offsetIntoBinaryTextSegment": 3777868, "subFrames": [
          {"binaryName": "libdyld.dylib", "binaryUUID": "\(dyldUUID)", "address": 7170808612,
           "offsetIntoBinaryTextSegment": 6948, "subFrames": [
            {"binaryName": "OpenSuperWhisper", "binaryUUID": "\(appUUID)", "address": 4365854092,
             "offsetIntoBinaryTextSegment": 3777932}]}]}
        """
    }

    func testEachFrameCarriesItsOffsetIntoTheBinary() {
        let parsed = CallStackTree.parse(tree(attributedFrames: appDyldApp))

        XCTAssertEqual(parsed.frames, [
            "OpenSuperWhisper 0x10439a54c +0x39a54c",
            "libdyld.dylib 0x1ab69db24 +0x1b24",
            "OpenSuperWhisper 0x10439a58c +0x39a58c",
        ])
    }

    func testEachBinaryIsListedOnceWithItsUUID() {
        let parsed = CallStackTree.parse(tree(attributedFrames: appDyldApp))

        XCTAssertEqual(parsed.images, [
            "image OpenSuperWhisper \(appUUID)",
            "image libdyld.dylib \(dyldUUID)",
        ])
    }

    func testAFrameWithoutOffsetOrUUIDStillYieldsALine() {
        let parsed = CallStackTree.parse(tree(attributedFrames: #"{"binaryName": "Bare", "address": 255}"#))

        XCTAssertEqual(parsed.frames, ["Bare 0xff"])
        XCTAssertEqual(parsed.images, [])
    }

    func testTheTreeWithoutItsWrapperIsReadToo() {
        let json = Data(#"{"callStacks": [{"callStackRootFrames": [{"binaryName": "A", "address": 16, "offsetIntoBinaryTextSegment": 4}]}]}"#.utf8)

        XCTAssertEqual(CallStackTree.parse(json).frames, ["A 0x10 +0x4"])
    }

    func testTheAttributedThreadIsChosenAndTheFrameLimitApplies() {
        let parsed = CallStackTree.parse(tree(attributedFrames: appDyldApp), limit: 2)

        XCTAssertEqual(parsed.frames.count, 2)
        XCTAssertFalse(parsed.frames.contains { $0.hasPrefix("Other") })
        XCTAssertEqual(parsed.images.count, 2)
    }

    func testUnexpectedJSONYieldsNothingInsteadOfCrashing() {
        for json in ["not json", "[]", #"{"callStacks": 3}"#, #"{"callStacks": [{}]}"#] {
            XCTAssertEqual(CallStackTree.parse(Data(json.utf8)), ParsedCallStack(frames: [], images: []), json)
        }
    }

    // MARK: - Message

    func testTheImageLinesFollowTheFrames() {
        let draft = CrashReportDraft(kind: .crash, cause: "c", frames: ["A 0x1 +0x1"],
                                     images: ["image A \(appUUID)"], appVersion: "1", osVersion: "26")

        XCTAssertEqual(CrashReport.message(for: draft, frameLimit: 1),
                       "crash: c\n#0 A 0x1 +0x1\nimage A \(appUUID)")
    }

    /// Frames are dropped from the bottom to fit; the image lines are never among them.
    func testAnOversizedStackKeepsEveryImageLine() {
        let frames = (0..<400).map { "VeryLongBinaryNameThatPadsEachFrameNicely_\($0) 0x000000010abcdef0 +0x39a54c" }
        let images = (0..<5).map { "image Binary\($0) \(appUUID)" }
        let draft = CrashReportDraft(kind: .crash, cause: "c", frames: frames, images: images,
                                     appVersion: "1", osVersion: "26")
        let submission = CrashReport.submission(for: draft)

        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
        XCTAssertFalse(submission.message.contains("#399 "))
        XCTAssertTrue(submission.message.contains("#0 "))
        for image in images { XCTAssertTrue(submission.message.contains(image)) }
    }
}
