import GRDB
import XCTest

@testable import OpenSuperWhisperCore

/// Where a dictation's measurement survives, and where it must not (#262). A rerun starts a new
/// engine run and clears the previous numbers; a restyle measures nothing new and keeps them; an
/// update for a row that was never written is a no-op rather than an insert.
@MainActor
final class RecordingTimingStoreTests: CoreTestCase {

    private var queue: DatabaseQueue!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        queue = try DatabaseQueue()
        store = try RecordingStore(databaseQueue: queue)
    }

    private func recording(id: UUID = UUID()) -> Recording {
        var timing = DictationTiming()
        timing.finalizeMs = 100
        timing.transcribeMs = 600
        timing.transcribeAttempts = 1
        timing.totalMs = 900
        return Recording(id: id, timestamp: Date(timeIntervalSince1970: 1_760_000_000),
                         fileName: "\(id.uuidString).wav", transcription: "as dictated",
                         duration: 3, status: .completed, progress: 1,
                         timingJSON: timing.encoded)
    }

    private func fetch(_ id: UUID) async throws -> Recording? {
        let rows = try await store.fetchRecordings(limit: 50, offset: 0)
        return rows.first { $0.id == id }
    }

    func testRerunClearsThePreviousMeasurement() async throws {
        let row = recording()
        try await store.addRecordingSync(row)

        await store.updateRecordingStatusOnly(row.id, progress: 0, status: .pending,
                                              isRegeneration: true, clearTiming: true)

        let saved = try await fetch(row.id)
        let fetched = try XCTUnwrap(saved)
        XCTAssertNil(fetched.timingJSON, "a new engine run must not inherit the old numbers")
        XCTAssertEqual(fetched.status, .pending)
        XCTAssertEqual(fetched.progress, 0)
        // `isRegeneration` is not a column: it lives on the in-memory value the caller updates,
        // and every row read back from the database carries false
        // (RecordingMigrationTests.testEveryColumnRoundTrips asserts exactly that).
    }

    /// The contrast that proves `clearTiming` is the mechanism rather than the update clobbering:
    /// the same progress update without it leaves the blob alone, which is what the import path
    /// relies on (a fresh INSERT already carries nil, and nothing later may disturb it).
    func testAProgressUpdateWithoutClearingKeepsTheBlob() async throws {
        let row = recording()
        try await store.addRecordingSync(row)

        await store.updateRecordingProgressOnlySync(row.id, transcription: "processed",
                                                    progress: 1, status: .completed)

        let saved = try await fetch(row.id)
        let fetched = try XCTUnwrap(saved)
        XCTAssertEqual(fetched.timingJSON, row.timingJSON)
        XCTAssertEqual(fetched.transcription, "processed")
    }

    /// A restyle runs the cleanup model again but no engine, so the dictation's own measurement
    /// stays exactly what it was.
    func testRestylePreservesTheMeasurement() async throws {
        let row = recording()
        try await store.addRecordingSync(row)

        try await store.restyle(row, transcription: "restyled text", styleUsed: "Pro",
                                cleanup: CleanupOutcome(text: "restyled text",
                                                        status: .cleaned(model: "m")))

        let saved = try await fetch(row.id)
        let fetched = try XCTUnwrap(saved)
        XCTAssertEqual(fetched.timingJSON, row.timingJSON, "a restyle measures no new run")
        XCTAssertEqual(fetched.transcription, "restyled text")
        XCTAssertEqual(fetched.styleUsed, "Pro")
    }

    /// A restyle rewrites only the text fields, from a fresh read. Handing it a `Recording` the
    /// caller has held since before the post-delivery update must not put the old blob back —
    /// the version that writes that struct wholesale reverts `insertMs`/`totalMs` (B2).
    func testRestyleFromAStaleCopyDoesNotRevertTheStoredBlob() async throws {
        let row = recording()
        try await store.addRecordingSync(row)
        // What a caller holds after reading the row: from before the post-delivery update lands.
        let stale = row

        var finished = try XCTUnwrap(row.timing)
        finished.insertMs = 40
        finished.totalMs = 940
        await store.updateTimingSync(row.id, timingJSON: finished.encoded)

        try await store.restyle(stale, transcription: "restyled text", styleUsed: "Pro",
                                cleanup: CleanupOutcome(text: "restyled text",
                                                        status: .cleaned(model: "m")))

        let saved = try await fetch(row.id)
        let fetched = try XCTUnwrap(saved)
        XCTAssertEqual(fetched.timing, finished,
                       "a stale copy must not put the pre-delivery blob back")
        XCTAssertEqual(fetched.transcription, "restyled text")
    }

    /// The post-delivery write re-encodes the whole blob. It must carry the stages that were on
    /// the row when it was created — a fresh default would silently erase the first half.
    func testUpdatingTimingCarriesEveryEarlierStage() async throws {
        let row = recording()
        try await store.addRecordingSync(row)
        var finished = try XCTUnwrap(row.timing)
        finished.insertMs = 40
        finished.totalMs = 940

        await store.updateTimingSync(row.id, timingJSON: finished.encoded)

        let saved = try await fetch(row.id)
        let fetched = try XCTUnwrap(saved)
        XCTAssertEqual(fetched.timing, finished)
        XCTAssertEqual(fetched.timing?.finalizeMs, 100)
        XCTAssertEqual(fetched.timing?.transcribeMs, 600)
        XCTAssertEqual(fetched.timing?.transcribeAttempts, 1)
    }

    /// An imported file has no stop press and no dictation behind it, so it records nothing —
    /// and the processing updates that follow must not invent a timing.
    func testAnImportRowStaysUnmeasuredThroughProcessing() async throws {
        let id = UUID()
        let row = Recording(id: id, timestamp: Date(timeIntervalSince1970: 1_760_000_000),
                            fileName: "\(id.uuidString).wav", transcription: "", duration: 0,
                            status: .pending, progress: 0)
        try await store.addRecordingSync(row)

        await store.updateRecordingProgressOnlySync(id, transcription: "imported text",
                                                    progress: 1, status: .completed)

        let saved = try await fetch(id)
        let fetched = try XCTUnwrap(saved)
        XCTAssertNil(fetched.timingJSON, "an import records nothing by design")
        XCTAssertEqual(fetched.transcription, "imported text")
    }

    /// History off means no row, and the post-delivery UPDATE must not create one. The UPDATE
    /// matching zero rows and the cache lookup finding no id are both no-ops.
    func testUpdatingTimingForAMissingRowDoesNotInsert() async throws {
        await store.updateTimingSync(UUID(), timingJSON: recording().timingJSON)

        let count = try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recordings") }
        XCTAssertEqual(count, 0)
    }
}
