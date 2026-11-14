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
                         appVersion: "0.14.0", appBuild: "63", osVersion: "26.2")
    }

    // MARK: - Message

    func testTheMessageLeadsWithTheCauseThenNumbersTheFrames() {
        let message = CrashReport.message(for: draft(frames: ["A 0x01", "B 0x02", "C 0x03"]),
                                          frameLimit: 3)

        XCTAssertEqual(message, "crash: EXC_BAD_ACCESS (SIGSEGV)\n#0 A 0x01\n#1 B 0x02\n#2 C 0x03")
    }

    /// Frames run from the crash site (#0) outward, so a limit cuts the outermost ones.
    func testTheFrameLimitKeepsTheTopOfTheStack() {
        let message = CrashReport.message(for: draft(frames: ["crash 0x01", "mid 0x02", "entry 0x03"]),
                                          frameLimit: 1)

        XCTAssertEqual(message, "crash: EXC_BAD_ACCESS (SIGSEGV)\n#0 crash 0x01")
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

    /// A stack far past the endpoint's byte limit still sends: the outermost frames (the end of the
    /// list) are dropped until it fits, and #0, the crash site, always survives.
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

    // MARK: - Context

    func testTheContextNamesVersionAndBuild() {
        XCTAssertEqual(CrashReport.details(for: draft(frames: [])), "OpenSuperWhisper 0.14.0 (63) · macOS 26.2")
    }

    /// MetricKit's `osVersion` already reads "macOS 27.2.1 (26B131)": no second prefix.
    func testAnOSVersionThatStartsWithMacOSIsNotPrefixedAgain() {
        var metricKit = draft(frames: [])
        metricKit.osVersion = "macOS 27.2.1 (26B131)"

        XCTAssertEqual(CrashReport.details(for: metricKit), "OpenSuperWhisper 0.14.0 (63) · macOS 27.2.1 (26B131)")
    }

    // MARK: - Cause details

    func testTheRegionAndTheExceptionGetOneCompactLineEachBelowTheCause() {
        var crash = draft(frames: ["A 0x01"])
        crash.memoryRegion = "    Freed heap region:\n  0x1000-0x2000\t[ 16K]\n\n  rw-/rwx  "
        crash.exceptionReason = CrashReport.exceptionReason(name: "NSInvalidArgumentException", className: "NSArray",
                                                            message: "index 3\nbeyond bounds")

        XCTAssertEqual(CrashReport.message(for: crash, frameLimit: 1), """
        crash: EXC_BAD_ACCESS (SIGSEGV)
        region: Freed heap region: 0x1000-0x2000 [ 16K] rw-/rwx
        exception: NSInvalidArgumentException (NSArray): index 3 beyond bounds
        #0 A 0x01
        """)
    }

    func testTheRegionAndTheExceptionAreCapped() {
        var crash = draft(frames: [])
        crash.memoryRegion = String(repeating: "r ", count: 500)
        crash.exceptionReason = String(repeating: "e", count: 500)
        let lines = CrashReport.message(for: crash, frameLimit: 0).split(separator: "\n")

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].count, "region: ".count + 300)
        XCTAssertEqual(lines[2].count, "exception: ".count + 300)
    }

    func testAbsentDetailsLeaveNoEmptyLine() {
        XCTAssertEqual(CrashReport.message(for: draft(frames: []), frameLimit: 0), "crash: EXC_BAD_ACCESS (SIGSEGV)")
    }

    func testTheBudgetStillHoldsWithBothDetailLines() {
        var crash = draft(frames: (0..<400).map { "VeryLongBinaryNameThatPadsEachFrameNicely_\($0) 0x000000010abcdef0" })
        crash.memoryRegion = String(repeating: "r", count: 1000)
        crash.exceptionReason = String(repeating: "e", count: 1000)
        let submission = CrashReport.submission(for: crash)

        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
        XCTAssertTrue(submission.message.contains("#0 "))
        XCTAssertTrue(submission.message.contains("region: "))
    }

    // MARK: - Diagnostic file

    func testTheDiagnosticIsAttachedAsJSONNamedAfterTheBuild() throws {
        var crash = draft(frames: [])
        crash.diagnosticJSON = Data(#"{"callStackTree": {}}"#.utf8)
        let attachment = try XCTUnwrap(CrashReport.submission(for: crash).attachment)

        XCTAssertEqual(attachment.filename, "crash-0.14.0-63.json")
        XCTAssertEqual(attachment.contentType, "application/json")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: attachment.data))
    }

    func testAHangIsNamedHang() throws {
        var hang = draft(frames: [])
        hang.kind = .hang
        hang.diagnosticJSON = Data("{}".utf8)

        XCTAssertEqual(CrashReport.attachment(for: hang)?.filename, "hang-0.14.0-63.json")
    }

    func testUnreadableJSONAttachesNothing() {
        var crash = draft(frames: [])
        crash.diagnosticJSON = Data("not json".utf8)

        XCTAssertNil(CrashReport.submission(for: crash).attachment)
        XCTAssertNil(CrashReport.submission(for: draft(frames: [])).attachment)
    }

    func testTheLocaleLeavesBeforeTheFileDoes() throws {
        var crash = draft(frames: [])
        crash.diagnosticJSON = Data(#"{"diagnosticMetaData": {"regionFormat": "fr_FR", "osVersion": "macOS 27"}}"#.utf8)
        let data = try XCTUnwrap(CrashReport.submission(for: crash).attachment).data

        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fr_FR"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("macOS 27"))
    }

    func testTheMultipartFormCarriesTheJSONFile() throws {
        var crash = draft(frames: [])
        crash.diagnosticJSON = Data(#"{"a":1}"#.utf8)
        let submission = CrashReport.submission(for: crash)
        let body = try XCTUnwrap(FeedbackSender.request(for: submission, attachment: submission.attachment).httpBody)

        XCTAssertTrue(String(decoding: body, as: UTF8.self)
            .contains("name=\"files\"; filename=\"crash-0.14.0-63.json\"\r\nContent-Type: application/json\r\n\r\n{\"a\":1}\r\n"))
    }
}

final class DiagnosticJSONTests: XCTestCase {

    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
    }

    func testRegionFormatIsRemovedAtEveryDepth() throws {
        let json = Data("""
        {"regionFormat": "fr_FR", "diagnosticMetaData": {"regionFormat": "fr_FR", "appBuildVersion": "73"},
         "list": [{"deep": {"regionFormat": "en_US", "kept": true}}]}
        """.utf8)
        let stripped = try object(DiagnosticJSON.withoutLocale(json))

        XCTAssertNil(stripped["regionFormat"])
        XCTAssertEqual(stripped["diagnosticMetaData"] as? [String: String], ["appBuildVersion": "73"])
        let deep = ((stripped["list"] as? [[String: Any]])?.first?["deep"]) as? [String: Any]
        XCTAssertEqual(deep?["kept"] as? Bool, true)
        XCTAssertNil(deep?["regionFormat"])
    }

    func testEverythingElseSurvives() throws {
        let json = Data(#"{"callStackTree": {"callStacks": [{"threadAttributed": true}]}, "n": 1.5, "s": "a/b"}"#.utf8)
        let stripped = try object(DiagnosticJSON.withoutLocale(json))

        XCTAssertEqual(stripped["n"] as? Double, 1.5)
        XCTAssertEqual(stripped["s"] as? String, "a/b")
        XCTAssertNotNil(stripped["callStackTree"])
    }

    func testInvalidJSONYieldsNothing() {
        for json in ["", "not json", "{\"a\":"] {
            XCTAssertNil(DiagnosticJSON.withoutLocale(Data(json.utf8)), json)
        }
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

        XCTAssertEqual(parsed.frames, [
            "OpenSuperWhisper 0x10439a54c +0x39a54c",
            "libdyld.dylib 0x1ab69db24 +0x1b24",
        ])
        XCTAssertEqual(parsed.images, [
            "image OpenSuperWhisper \(appUUID)",
            "image libdyld.dylib \(dyldUUID)",
        ])
    }

    /// A linear chain `depth` frames deep, shaped as MetricKit sends a crash: `f0`, the root, is the
    /// crash site and `f<depth-1>` the thread's entry.
    private func chain(depth: Int) -> Data {
        var json = #"{"binaryName": "f\#(depth - 1)", "address": \#(depth - 1)}"#
        for index in stride(from: depth - 2, through: 0, by: -1) {
            json = #"{"binaryName": "f\#(index)", "address": \#(index), "subFrames": [\#(json)]}"#
        }
        return tree(attributedFrames: json)
    }

    func testTheCrashSiteComesFirstAndSurvivesTheFrameLimit() {
        let limit = CallStackTree.defaultFrameLimit
        let depth = limit + 40
        let parsed = CallStackTree.parse(chain(depth: depth))

        XCTAssertEqual(parsed.frames.count, limit)
        XCTAssertEqual(parsed.frames.first, "f0 0x0")
        XCTAssertEqual(parsed.frames.last, "f\(limit - 1) 0x\(String(limit - 1, radix: 16))")
        XCTAssertFalse(parsed.frames.contains { $0.hasPrefix("f\(depth - 1) ") })
    }

    func testTheImageLinesCoverOnlyTheFramesKept() {
        let json = #"{"binaryName": "Crash", "binaryUUID": "C", "address": 2, "subFrames": [{"binaryName": "Entry", "binaryUUID": "E", "address": 1}]}"#
        let parsed = CallStackTree.parse(tree(attributedFrames: json), limit: 1)

        XCTAssertEqual(parsed.frames, ["Crash 0x2"])
        XCTAssertEqual(parsed.images, ["image Crash C"])
    }

    func testUnexpectedJSONYieldsNothingInsteadOfCrashing() {
        for json in ["not json", "[]", #"{"callStacks": 3}"#, #"{"callStacks": [{}]}"#] {
            XCTAssertEqual(CallStackTree.parse(Data(json.utf8)), ParsedCallStack(frames: [], images: []), json)
        }
    }

    // MARK: - Message

    func testTheImageLinesFollowTheFrames() {
        let draft = CrashReportDraft(kind: .crash, cause: "c", frames: ["A 0x1 +0x1"],
                                     images: ["image A \(appUUID)"], appVersion: "1", appBuild: "2", osVersion: "26")

        XCTAssertEqual(CrashReport.message(for: draft, frameLimit: 1),
                       "crash: c\n#0 A 0x1 +0x1\nimage A \(appUUID)")
    }

    /// The outermost frames are dropped to fit; the image lines are never among them.
    func testAnOversizedStackKeepsEveryImageLine() {
        let frames = (0..<400).map { "VeryLongBinaryNameThatPadsEachFrameNicely_\($0) 0x000000010abcdef0 +0x39a54c" }
        let images = (0..<5).map { "image Binary\($0) \(appUUID)" }
        let draft = CrashReportDraft(kind: .crash, cause: "c", frames: frames, images: images,
                                     appVersion: "1", appBuild: "2", osVersion: "26")
        let submission = CrashReport.submission(for: draft)

        XCTAssertTrue(FeedbackSender.fitsLimits(submission))
        XCTAssertFalse(submission.message.contains("#399 "))
        XCTAssertTrue(submission.message.contains("#0 "))
        for image in images { XCTAssertTrue(submission.message.contains(image)) }
    }

    /// The trim walks in from the end of the list, the outermost frames, and stops before #0.
    func testTheSizeTrimDropsTheOutermostFramesAndNeverTheCrashSite() {
        let frames = (0..<400).map { "VeryLongBinaryNameThatPadsEachFrameNicely_\($0) 0x000000010abcdef0" }
        let submission = CrashReport.submission(for: CrashReportDraft(kind: .crash, cause: "c", frames: frames,
                                                                      appVersion: "1", appBuild: "2", osVersion: "26"))
        let kept = submission.message.split(separator: "\n").filter { $0.hasPrefix("#") }

        XCTAssertLessThan(kept.count, frames.count)
        for (index, line) in kept.enumerated() {
            XCTAssertTrue(line.hasPrefix("#\(index) VeryLongBinaryNameThatPadsEachFrameNicely_\(index) "), String(line))
        }
    }
}
