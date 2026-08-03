import GRDB
import XCTest
@testable import WhisperCore
@testable import OpenSuperWhisper

/// Commit 0, scenario 3: pin the retention policy — age cutoff, max-count, active-status
/// exclusion, union semantics, file deletion, and the add-then-enforce buffer behavior —
/// against in-memory GRDB. Preferences are driven through AppPreferences.shared with
/// full save/restore (hosted tests share the app's real defaults).
@MainActor
final class RecordingStoreRetentionTests: XCTestCase {

    private var store: RecordingStore!
    private var prefs: AppPreferences { AppPreferences.shared }
    private var saved: (
        countEnabled: Bool, count: Int, ageEnabled: Bool, ageValue: Int, ageUnit: String
    )!

    override func setUp() {
        super.setUp()
        store = try! RecordingStore(dbQueue: DatabaseQueue())
        saved = (prefs.retentionMaxCountEnabled, prefs.retentionMaxCount,
                 prefs.retentionMaxAgeEnabled, prefs.retentionMaxAgeValue,
                 prefs.retentionMaxAgeUnit)
        // Default every test to an inactive policy; each test opts in explicitly.
        prefs.retentionMaxCountEnabled = false
        prefs.retentionMaxAgeEnabled = false
    }

    override func tearDown() {
        prefs.retentionMaxCountEnabled = saved.countEnabled
        prefs.retentionMaxCount = saved.count
        prefs.retentionMaxAgeEnabled = saved.ageEnabled
        prefs.retentionMaxAgeValue = saved.ageValue
        prefs.retentionMaxAgeUnit = saved.ageUnit
        super.tearDown()
    }

    private func makeRecording(
        age: TimeInterval = 0,
        status: RecordingStatus = .completed
    ) -> Recording {
        let id = UUID()
        return Recording(id: id, timestamp: Date().addingTimeInterval(-age),
                         fileName: "\(id.uuidString).wav", transcription: "text",
                         duration: 1.0, status: status, progress: 1.0)
    }

    private func storedIDs() async throws -> Set<UUID> {
        Set(try await store.fetchRecordings(limit: 100, offset: 0).map { $0.id })
    }

    func testInactivePolicyDeletesNothing() async throws {
        for _ in 0..<5 { try await store.addRecordingSync(makeRecording(age: 30 * 86400)) }
        let deleted = await store.enforceRetentionPolicy()
        XCTAssertEqual(deleted, 0, "both switches off → policy inactive → nothing deleted")
        let ids = try await storedIDs()
        XCTAssertEqual(ids.count, 5)
    }

    func testAgePolicyDeletesExpiredFinishedKeepsActiveAndRecent() async throws {
        let expiredCompleted = makeRecording(age: 2 * 86400)
        let expiredFailed = makeRecording(age: 2 * 86400, status: .failed)
        let expiredPending = makeRecording(age: 2 * 86400, status: .pending)
        let recent = makeRecording(age: 3600)
        for recording in [expiredCompleted, expiredFailed, expiredPending, recent] {
            try await store.addRecordingSync(recording)
        }

        prefs.retentionMaxAgeEnabled = true
        prefs.retentionMaxAgeValue = 1
        prefs.retentionMaxAgeUnit = "days"

        let deleted = await store.enforceRetentionPolicy()
        XCTAssertEqual(deleted, 2, "expired completed + expired failed deleted")

        let remaining = try await storedIDs()
        XCTAssertTrue(remaining.contains(expiredPending.id),
                      "in-progress recordings are never removed, even when expired")
        XCTAssertTrue(remaining.contains(recent.id))
        XCTAssertFalse(remaining.contains(expiredCompleted.id))
        XCTAssertFalse(remaining.contains(expiredFailed.id))
    }

    func testCountPolicyKeepsNewestNFinishedOnly() async throws {
        let pending = makeRecording(status: .pending)
        var finished: [Recording] = []
        for index in 0..<5 {
            finished.append(makeRecording(age: TimeInterval(index * 100)))
        }
        try await store.addRecordingSync(pending)
        for recording in finished { try await store.addRecordingSync(recording) }

        prefs.retentionMaxCountEnabled = true
        prefs.retentionMaxCount = 2

        let deleted = await store.enforceRetentionPolicy()
        XCTAssertEqual(deleted, 3, "5 finished, keep newest 2 → 3 deleted")

        let remaining = try await storedIDs()
        XCTAssertTrue(remaining.contains(pending.id), "active recordings never count toward the limit")
        XCTAssertTrue(remaining.contains(finished[0].id) && remaining.contains(finished[1].id),
                      "the two NEWEST finished recordings survive")
    }

    func testCombinedAgeAndCountPoliciesDeleteTheUnion() async throws {
        let expired = makeRecording(age: 10 * 86400)          // caught by age
        let recent1 = makeRecording(age: 100)
        let recent2 = makeRecording(age: 200)
        let recent3 = makeRecording(age: 300)                  // caught by count (3rd newest)
        for recording in [expired, recent1, recent2, recent3] {
            try await store.addRecordingSync(recording)
        }

        prefs.retentionMaxAgeEnabled = true
        prefs.retentionMaxAgeValue = 1
        prefs.retentionMaxAgeUnit = "days"
        prefs.retentionMaxCountEnabled = true
        prefs.retentionMaxCount = 2

        let deleted = await store.enforceRetentionPolicy()
        XCTAssertEqual(deleted, 2, "age catches the expired row; count drops the 3rd newest — union, no double-count")
        let remaining = try await storedIDs()
        XCTAssertEqual(remaining, [recent1.id, recent2.id])
    }

    func testEnforcementDeletesTheRecordingFiles() async throws {
        // The one test that touches the real recordings directory: a uniquely-named file,
        // created by this test and removed by enforcement (defer-cleanup as a backstop).
        let directory = Recording.recordingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expired = makeRecording(age: 2 * 86400)
        let fileURL = directory.appendingPathComponent(expired.fileName)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("wav".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await store.addRecordingSync(expired)
        prefs.retentionMaxAgeEnabled = true
        prefs.retentionMaxAgeValue = 1
        prefs.retentionMaxAgeUnit = "days"

        let deleted = await store.enforceRetentionPolicy()
        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "enforcement removes the expired recording's audio file")
        let remaining = try await storedIDs()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAddRecordingTriggersEnforcementButSyncVariantDoesNot() async throws {
        prefs.retentionMaxCountEnabled = true
        prefs.retentionMaxCount = 1

        // addRecordingSync: insert + notify ONLY — no enforcement pass.
        try await store.addRecordingSync(makeRecording())
        try await store.addRecordingSync(makeRecording())
        let afterSyncInserts = try await storedIDs()
        XCTAssertEqual(afterSyncInserts.count, 2,
                       "the Sync path must not enforce — it exists for ordered bulk writes")

        // addRecording (fire-and-forget): enforces after inserting → store converges to the limit.
        store.addRecording(makeRecording())
        let deadline = Date().addingTimeInterval(5)
        var converged = false
        while Date() < deadline {
            if try await storedIDs().count == 1 { converged = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(converged, "addRecording must enforce the count limit after inserting")
    }
}
