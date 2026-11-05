import GRDB
import XCTest

@testable import OpenSuperWhisperCore

/// The queue's two non-vocal paths (#262): a rerun must clear the previous run's numbers at the
/// call site that starts it, and an imported file must never claim a measurement it does not
/// have. Both are tested through `TranscriptionQueue` rather than the store methods it calls —
/// deleting the wiring would leave a store-level test green (M4, M6).
@MainActor
final class TranscriptionQueueTimingTests: CoreTestCase {

    private var database: DatabaseQueue!
    private var store: RecordingStore!

    private final class StubEngine: TranscriptionEngine {
        let engineName = "Stub"
        let isModelLoaded = true
        func initialize() async throws {}
        func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String {
            "stub text"
        }
        func cancelTranscription() {}
        func getSupportedLanguages() -> [String] { [] }
    }

    override func setUpWithError() throws {
        database = try DatabaseQueue()
        store = try RecordingStore(databaseQueue: database)
        try? FileManager.default.createDirectory(at: Recording.recordingsDirectory,
                                                 withIntermediateDirectories: true)
    }

    private func makeQueue() -> TranscriptionQueue {
        TranscriptionQueue(transcriptionService: TranscriptionService(engineBuilder: { _ in StubEngine() }),
                           recordingStore: store,
                           makeSettings: { Fixtures.pinnedSettings() },
                           confirmEnableHistory: { false })
    }

    private func timingBlob() -> String {
        var timing = DictationTiming()
        timing.finalizeMs = 100
        timing.transcribeMs = 600
        timing.transcribeAttempts = 1
        timing.totalMs = 900
        return timing.encoded ?? ""
    }

    /// The clear lives in `requeueRecording`'s call to `updateRecordingStatusOnly`. Removing
    /// `clearTiming: true` there leaves the store-level test green, so this is the assertion
    /// that pins the wiring.
    func testRequeueClearsThePreviousMeasurementAtTheCallSite() async throws {
        CoreTestEnvironment.preferences.saveTranscriptionHistory = true
        let id = UUID()
        let row = Recording(id: id, timestamp: Date(timeIntervalSince1970: 1_760_000_000),
                            fileName: "\(id.uuidString).wav", transcription: "old text",
                            duration: 3, status: .completed, progress: 1,
                            timingJSON: timingBlob())
        try await store.addRecordingSync(row)
        // `existingAudioSource` only requeues a row whose audio it can find.
        try Data("RIFF".utf8).write(to: row.url)

        await makeQueue().requeueRecording(row)

        let saved = try await store.fetchRecording(id: id)
        let fetched = try XCTUnwrap(saved)
        XCTAssertNil(fetched.timingJSON, "the previous run's numbers must not survive the rerun")
    }

    /// An import is a fresh row with no stop press and no dictation behind it. The producer,
    /// not a replay of the shape, is what this drives: nothing on the import path may stamp a
    /// measurement.
    func testAnImportedFileGetsNoMeasurement() async throws {
        CoreTestEnvironment.preferences.saveTranscriptionHistory = true
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osw-import-\(UUID().uuidString).wav")
        try Data("RIFF".utf8).write(to: file)

        let before = Set((try await store.fetchRecordings(limit: 100, offset: 0)).map(\.id))
        await makeQueue().addFileToQueue(url: file)

        let rows = try await store.fetchRecordings(limit: 100, offset: 0)
        let imported = try XCTUnwrap(rows.first { !before.contains($0.id) })
        XCTAssertNil(imported.timingJSON, "an import records nothing by design")
        XCTAssertEqual(imported.sourceFileURL, file.path)
    }
}
