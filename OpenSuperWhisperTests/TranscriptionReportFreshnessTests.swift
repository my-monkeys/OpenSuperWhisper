import GRDB
import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// A report is built from a row that may have changed since the feed copied it (#262). The
/// post-delivery timing write lands after the row is first shown, so a save built from the value
/// the feed holds can print `total —` and `insert —`: the two stages the feature exists to
/// measure. The save path re-reads the row, and this pins that (B1).
@MainActor
final class TranscriptionReportFreshnessTests: XCTestCase {

    private func recording(id: UUID, timing: DictationTiming?) -> Recording {
        Recording(id: id, timestamp: Date(timeIntervalSince1970: 1_760_000_000),
                  fileName: "\(id.uuidString).wav", transcription: "the words",
                  duration: 3, status: .completed, progress: 1, timingJSON: timing?.encoded)
    }

    func testAReportSavedFromAStaleCopyCarriesThePostDeliveryStages() async throws {
        let database = try DatabaseQueue()
        let store = try RecordingStore(databaseQueue: database)
        let id = UUID()
        var stored = DictationTiming()
        stored.finalizeMs = 100
        stored.transcribeMs = 600
        stored.totalMs = 900
        let row = recording(id: id, timing: stored)
        try await store.addRecordingSync(row)
        // What the feed holds: copied before the post-delivery update.
        let stale = row

        var finished = try XCTUnwrap(row.timing)
        finished.insertMs = 40
        finished.totalMs = 940
        await store.updateTimingSync(id, timingJSON: finished.encoded)

        let model = TranscriptionReportsModel(store: store,
                                              appDetails: { "test details" },
                                              languageSetting: { "en" })
        try await model.save(ReportDraft(problem: .other), for: stale)

        let saved = try await store.fetchReports()
        let report = try XCTUnwrap(saved.first)
        XCTAssertEqual(report.timing?.insertMs, 40,
                       "the report must read the row, not the stale copy it was handed")
        XCTAssertEqual(report.timing?.totalMs, 940)
        XCTAssertEqual(report.ending, .insertion)
    }
}
