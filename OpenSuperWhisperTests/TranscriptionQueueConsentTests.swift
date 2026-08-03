import GRDB
import XCTest
@testable import WhisperCore
@testable import OpenSuperWhisper

/// S-1 (PR #57 review cycle 1): pin the TranscriptionQueue consent seam extracted at
/// e88da37 — the only behavior-changing delta in the extraction that shipped without
/// coverage. Full decision table for `addFileToQueue(url:)`:
///
///   history OFF + closure nil   → silent cancel (FAIL-SAFE), no store write
///   history OFF + closure false → cancel after consulting, no store write
///   history OFF + closure true  → flips saveTranscriptionHistory, recording enqueued
///   history ON                  → gate skipped, closure never consulted
///
/// All paths run against an in-memory RecordingStore via the init(recordingStore:)
/// seam — the shared singletons' on-disk database is never touched. Enqueuing paths
/// (grant/skip) auto-start background processing; prefs point the engine at a
/// nonexistent model so the background transcription fails fast on any host. The
/// assertions below only use facts fixed at the moment addFileToQueue returns
/// (pref value, row existence, sourceFileURL) — background status flips are
/// timing-dependent and deliberately NOT asserted.
@MainActor
final class TranscriptionQueueConsentTests: XCTestCase {

    /// Repo root = two levels up from this file (same #filePath contract as
    /// WhisperEngineSmokeTests: valid because the gate builds+tests one checkout).
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var fixtureURL: URL { Self.repoRoot.appendingPathComponent("jfk.wav") }

    private var prefs: AppPreferences { AppPreferences.shared }
    private var saved: (history: Bool, engine: String, modelPath: String?)!
    private var store: RecordingStore!
    private var queue: TranscriptionQueue!

    override func setUp() {
        super.setUp()
        saved = (prefs.saveTranscriptionHistory, prefs.selectedEngine, prefs.selectedWhisperModelPath)
        store = try! RecordingStore(dbQueue: DatabaseQueue())
        queue = TranscriptionQueue(recordingStore: store)
        // Fail the background transcription fast (no model load, no download) on the
        // grant/skip paths that start processing.
        prefs.selectedEngine = "whisper"
        prefs.selectedWhisperModelPath = "/nonexistent/OSWTests-no-such-model.bin"
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path),
                      "jfk.wav must exist at repo root (compile-time #filePath: \(fixtureURL.path))")
    }

    override func tearDown() {
        queue.confirmEnableHistory = nil
        prefs.saveTranscriptionHistory = saved.history
        prefs.selectedEngine = saved.engine
        prefs.selectedWhisperModelPath = saved.modelPath
        queue = nil
        store = nil
        // Neighbor hygiene: the enqueueing tests' background transcription fails on the
        // shared service and may leave engineError set. reloadEngine() clears it
        // synchronously (per TranscriptionServiceErrorStateTests) so no stale error
        // leaks into later classes.
        TranscriptionService.shared.reloadEngine()
        super.tearDown()
    }

    private func storedRows() async throws -> [Recording] {
        try await store.fetchRecordings(limit: 10, offset: 0)
    }

    /// Await the auto-started background processing settling (isProcessing flips false
    /// after the recording terminally fails on the bogus model path). CONTAINMENT:
    /// without this the background task can outlive the test and leave an in-flight
    /// engine load on TranscriptionService.shared — a cross-class pollution channel
    /// (RecordButtonDisabledStateTests asserts isLoading == false on that singleton).
    /// Same poll pattern as RecordingStoreTests.awaitEventually.
    private func awaitProcessingSettles(_ description: String = "background processing settles",
                                        timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !queue.isProcessing { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    // (a) FAIL-SAFE: history off, no closure wired → silent cancel, nothing persisted.
    func testNilConsentClosureCancelsSilently() async throws {
        prefs.saveTranscriptionHistory = false
        XCTAssertNil(queue.confirmEnableHistory, "fail-safe default must be an unwired closure")

        await queue.addFileToQueue(url: fixtureURL)

        XCTAssertFalse(prefs.saveTranscriptionHistory,
                       "cancel path must not flip the history preference")
        let rows = try await storedRows()
        XCTAssertTrue(rows.isEmpty,
                      "cancel path must not persist a recording")
        XCTAssertFalse(queue.isProcessing, "cancel path must not start processing")
        XCTAssertNil(queue.currentRecordingId, "cancel path must not claim a recording")
    }

    // (b) history off, closure declines → cancel after consulting, nothing persisted.
    func testDecliningConsentCancels() async throws {
        prefs.saveTranscriptionHistory = false
        var consulted = false
        queue.confirmEnableHistory = { consulted = true; return false }

        await queue.addFileToQueue(url: fixtureURL)

        XCTAssertTrue(consulted, "history-off path must consult the wired closure")
        XCTAssertFalse(prefs.saveTranscriptionHistory,
                       "declined consent must not flip the history preference")
        let rows = try await storedRows()
        XCTAssertTrue(rows.isEmpty,
                      "declined consent must not persist a recording")
        XCTAssertFalse(queue.isProcessing, "declined consent must not start processing")
    }

    // (c) history off, closure grants → pref flips true and the recording is enqueued.
    func testGrantingConsentFlipsPreferenceAndEnqueues() async throws {
        prefs.saveTranscriptionHistory = false
        queue.confirmEnableHistory = { true }

        await queue.addFileToQueue(url: fixtureURL)

        XCTAssertTrue(prefs.saveTranscriptionHistory,
                      "granted consent must flip the history preference (the prompt's 'Enable & Save')")
        let rows = try await storedRows()
        XCTAssertEqual(rows.count, 1, "granted consent must enqueue exactly one recording")
        XCTAssertEqual(rows.first?.sourceFileURL, fixtureURL.path,
                       "the enqueued recording must point at the dropped source file")
        XCTAssertTrue(rows.first?.fileName.hasSuffix(".wav") ?? false,
                      "the enqueued recording must get a .wav store filename")
        await awaitProcessingSettles()
    }

    // (d) history already on → the gate is skipped entirely; a wired closure (even a
    // declining one) is never consulted.
    func testHistoryEnabledSkipsConsentGate() async throws {
        prefs.saveTranscriptionHistory = true
        var consulted = false
        queue.confirmEnableHistory = { consulted = true; return false }

        await queue.addFileToQueue(url: fixtureURL)

        XCTAssertFalse(consulted, "history-on path must not consult the consent closure")
        XCTAssertTrue(prefs.saveTranscriptionHistory, "history preference must stay on")
        let rows = try await storedRows()
        XCTAssertEqual(rows.count, 1,
                       "history-on path must enqueue the recording")
        await awaitProcessingSettles()
    }
}
