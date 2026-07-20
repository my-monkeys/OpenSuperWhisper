import GRDB
import XCTest
@testable import OpenSuperWhisper

/// Commit 0, scenario 2 (store behavior): pin RecordingStore's CRUD, pending-queue
/// ordering, search, progress-only updates, and notification posts against in-memory
/// GRDB. All writes go through the *Sync paths for determinism; the one fire-and-forget
/// path under test (deleteRecording) is awaited by polling.
@MainActor
final class RecordingStoreTests: XCTestCase {

    private var store: RecordingStore!

    override func setUp() {
        super.setUp()
        store = try! RecordingStore(dbQueue: DatabaseQueue())
    }

    private func makeRecording(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        status: RecordingStatus = .completed,
        transcription: String = "text",
        progress: Float = 1.0
    ) -> Recording {
        Recording(id: id, timestamp: timestamp, fileName: "\(id.uuidString).wav",
                  transcription: transcription, duration: 1.0, status: status, progress: progress)
    }

    /// Poll until `condition` holds or the deadline passes; fails the test on timeout.
    private func awaitEventually(
        _ description: String,
        timeout: TimeInterval = 5,
        condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    // MARK: - Insert + fetch

    func testFetchOrdersByTimestampDescendingAndPages() async throws {
        let oldest = makeRecording(timestamp: Date(timeIntervalSince1970: 100))
        let middle = makeRecording(timestamp: Date(timeIntervalSince1970: 200))
        let newest = makeRecording(timestamp: Date(timeIntervalSince1970: 300))
        for recording in [middle, newest, oldest] {  // insert out of order on purpose
            try await store.addRecordingSync(recording)
        }

        let all = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(all.map { $0.id }, [newest.id, middle.id, oldest.id])

        let page = try await store.fetchRecordings(limit: 1, offset: 1)
        XCTAssertEqual(page.map { $0.id }, [middle.id], "limit/offset paging must be stable")
    }

    func testFetchOnEmptyStoreReturnsEmpty() async throws {
        let empty = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(empty, [])
        XCTAssertNil(store.getNextPendingRecording())
        XCTAssertEqual(store.getPendingRecordings(), [])
    }

    // MARK: - Pending queue

    func testPendingQueueFiltersActiveStatusesAscending() async throws {
        let pendingNew = makeRecording(timestamp: Date(timeIntervalSince1970: 300), status: .pending, progress: 0)
        let converting = makeRecording(timestamp: Date(timeIntervalSince1970: 100), status: .converting, progress: 0.2)
        let transcribing = makeRecording(timestamp: Date(timeIntervalSince1970: 200), status: .transcribing, progress: 0.5)
        let completed = makeRecording(timestamp: Date(timeIntervalSince1970: 50), status: .completed)
        let failed = makeRecording(timestamp: Date(timeIntervalSince1970: 25), status: .failed)
        for recording in [pendingNew, converting, transcribing, completed, failed] {
            try await store.addRecordingSync(recording)
        }

        let queue = store.getPendingRecordings()
        XCTAssertEqual(queue.map { $0.id }, [converting.id, transcribing.id, pendingNew.id],
                       "active statuses only (pending/converting/transcribing), oldest first")
        XCTAssertEqual(store.getNextPendingRecording()?.id, converting.id,
                       "next pending is the earliest active recording")
    }

    // MARK: - Updates

    func testUpdateRecordingSyncPersistsAndPostsNotification() async throws {
        let recording = makeRecording(transcription: "before")
        try await store.addRecordingSync(recording)

        var edited = recording
        edited.transcription = "after"
        let posted = expectation(forNotification: RecordingStore.recordingsDidUpdateNotification, object: nil)
        try await store.updateRecordingSync(edited)
        await fulfillment(of: [posted], timeout: 5)

        let fetched = try await store.fetchRecordings(limit: 1, offset: 0)
        XCTAssertEqual(fetched.first?.transcription, "after")
    }

    func testProgressOnlySyncUpdatesDbCacheAndPostsNotification() async throws {
        let recording = makeRecording(status: .transcribing, transcription: "partial", progress: 0.4)
        try await store.addRecordingSync(recording)

        let posted = expectation(forNotification: RecordingStore.recordingProgressDidUpdateNotification, object: nil)
        await store.updateRecordingProgressOnlySync(
            recording.id, transcription: "final", progress: 1.0, status: .completed,
            isRegeneration: false, modelUsed: "whisper-tiny", wasFallback: true)
        await fulfillment(of: [posted], timeout: 5)

        let fetched = try await store.fetchRecordings(limit: 1, offset: 0)
        let row = try XCTUnwrap(fetched.first)
        XCTAssertEqual(row.transcription, "final")
        XCTAssertEqual(row.progress, 1.0)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.modelUsed, "whisper-tiny")
        XCTAssertTrue(row.wasFallback)

        // The @Published recordings array is NOT a write-through cache: nothing in the
        // store's public surface bulk-populates it (grep: no appends — only incremental
        // mutations of already-present entries, which none ever are). After insert +
        // progress-update it remains EMPTY; the read models are fetch*/search* and the
        // update signal is the notifications. Pin that exactly (smell — see HANDOFF).
        XCTAssertTrue(store.recordings.isEmpty,
                      "recordings cache is never populated by any public write path")
    }

    func testProgressOnlySyncLeavesModelFieldsUntouchedWhenNil() async throws {
        let recording = makeRecording(status: .completed)
        try await store.addRecordingSync(recording)
        await store.updateRecordingProgressOnlySync(
            recording.id, transcription: "v1", progress: 1.0, status: .completed,
            modelUsed: "whisper-tiny", wasFallback: true)

        // Second call WITHOUT the optional fields: they must survive, not be cleared.
        await store.updateRecordingProgressOnlySync(
            recording.id, transcription: "v2", progress: 1.0, status: .completed)

        let row = try await store.fetchRecordings(limit: 1, offset: 0).first
        XCTAssertEqual(row?.transcription, "v2")
        XCTAssertEqual(row?.modelUsed, "whisper-tiny", "nil modelUsed must not clobber the stored value")
        XCTAssertEqual(row?.wasFallback, true, "nil wasFallback must not clobber the stored value")
    }

    func testUpdateSourceFileURLPersists() async throws {
        let recording = makeRecording()
        try await store.addRecordingSync(recording)
        try await store.updateSourceFileURL(recording.id, sourceURL: "/tmp/imported.m4a")
        let row = try await store.fetchRecordings(limit: 1, offset: 0).first
        XCTAssertEqual(row?.sourceFileURL, "/tmp/imported.m4a")
        XCTAssertEqual(row?.sourceFileName, "imported.m4a")
    }

    func testUpdateStatusOnlySyncUpdatesProgressAndStatus() async throws {
        let recording = makeRecording(status: .pending, progress: 0)
        try await store.addRecordingSync(recording)
        await store.updateRecordingStatusOnly(recording.id, progress: 0.75, status: .transcribing)
        let row = try await store.fetchRecordings(limit: 1, offset: 0).first
        XCTAssertEqual(row?.status, .transcribing)
        XCTAssertEqual(row?.progress, 0.75)
    }

    // MARK: - Delete

    func testDeleteCompletedRecordingRemovesRowAndPostsNotification() async throws {
        let recording = makeRecording(status: .completed)
        try await store.addRecordingSync(recording)

        let posted = expectation(forNotification: RecordingStore.recordingsDidUpdateNotification, object: nil)
        store.deleteRecording(recording)  // fire-and-forget Task; completed → no queue coupling
        await fulfillment(of: [posted], timeout: 5)

        await awaitEventually("row removal after deleteRecording") {
            await ((try? self.store.fetchRecordings(limit: 10, offset: 0))?.isEmpty ?? false)
        }
    }

    // MARK: - Search

    func testSearchIsCaseInsensitiveOrderedDescending() async throws {
        let older = makeRecording(timestamp: Date(timeIntervalSince1970: 100), transcription: "Hello World")
        let newer = makeRecording(timestamp: Date(timeIntervalSince1970: 200), transcription: "say hello again")
        let other = makeRecording(timestamp: Date(timeIntervalSince1970: 300), transcription: "unrelated")
        for recording in [older, newer, other] {
            try await store.addRecordingSync(recording)
        }

        let hits = store.searchRecordings(query: "HELLO")
        XCTAssertEqual(hits.map { $0.id }, [newer.id, older.id],
                       "nocase LIKE match, newest first, non-matching row excluded")
        XCTAssertEqual(store.searchRecordings(query: "nothing matches this"), [])
    }
}
