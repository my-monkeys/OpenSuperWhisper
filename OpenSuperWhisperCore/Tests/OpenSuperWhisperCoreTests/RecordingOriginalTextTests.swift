import GRDB
import XCTest

@testable import OpenSuperWhisperCore

/// What happens to a dictation's kept original when the queue rewrites the row (#168). An import
/// or a rerun stores its own text as the original, since that text is the engine's; a progress
/// update that does not finish anything leaves the original alone.
@MainActor
final class RecordingOriginalTextTests: CoreTestCase {

    private var queue: DatabaseQueue!
    private var store: RecordingStore!
    private var recording: Recording!

    override func setUp() async throws {
        queue = try DatabaseQueue()
        store = try RecordingStore(databaseQueue: queue)
        recording = Recording(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_760_000_000), fileName: "r.wav",
                              transcription: "Send the mockups.", duration: 2, status: .completed, progress: 1,
                              rawTranscription: "um send the mock ups")
        let recording = recording!
        try await queue.write { db in try recording.insert(db) }
    }

    private func stored() async throws -> Recording? {
        let id = recording.id
        return try await queue.read { db in try Recording.filter(Recording.Columns.id == id).fetchOne(db) }
    }

    /// The progress notification for one update, caught while `update` runs.
    private func notification(during update: () async -> Void) async throws -> [AnyHashable: Any] {
        var caught: [AnyHashable: Any]?
        let observer = NotificationCenter.default.addObserver(
            forName: RecordingStore.recordingProgressDidUpdateNotification, object: nil, queue: nil
        ) { caught = $0.userInfo }
        defer { NotificationCenter.default.removeObserver(observer) }
        await update()
        return try XCTUnwrap(caught)
    }

    /// Rewriting a row in another style (#160) replaces the text and names the style, and keeps
    /// the engine's original, which is what the next rewrite starts from.
    func testARestyleKeepsTheOriginal() async throws {
        try await store.restyle(recording, transcription: "Please send the mock-ups.", styleUsed: "Pro",
                                cleanup: CleanupOutcome(text: "Please send the mock-ups.", status: .cleaned(model: "m")))

        let row = try await stored()
        XCTAssertEqual(row?.transcription, "Please send the mock-ups.")
        XCTAssertEqual(row?.styleUsed, "Pro")
        XCTAssertEqual(row?.rawTranscription, "um send the mock ups")
    }

    /// The pass that just ran replaces what the row kept from the previous one (#266).
    func testARestyleReplacesTheCleanupOutcome() async throws {
        var failed = recording!
        failed.cleanupModel = "old-model"
        failed.cleanupError = "401 Invalid API key"
        let seed = failed
        try await queue.write { db in try seed.update(db) }

        try await store.restyle(seed, transcription: "Please send the mock-ups.", styleUsed: "Pro",
                                cleanup: CleanupOutcome(text: "x", status: .cleaned(model: "new-model")))
        var row = try await stored()
        XCTAssertEqual(row?.cleanupModel, "new-model")
        XCTAssertNil(row?.cleanupError)

        try await store.restyle(try XCTUnwrap(row), transcription: "um send the mock ups", styleUsed: "Pro",
                                cleanup: CleanupOutcome(text: "x", status: .failed(model: "new-model", reason: "429 Slow down")))
        row = try await stored()
        XCTAssertEqual(row?.cleanupModel, "new-model")
        XCTAssertEqual(row?.cleanupError, "429 Slow down")
    }

    /// A rerun's text is the engine's own, so the cleanup outcome of the old text no longer applies.
    func testARerunClearsTheCleanupOutcome() async throws {
        var cleaned = recording!
        cleaned.cleanupModel = "old-model"
        cleaned.cleanupError = "boom"
        let seed = cleaned
        try await queue.write { db in try seed.update(db) }

        await store.updateRecordingProgressOnlySync(recording.id, transcription: "Rerun text", progress: 1,
                                                    status: .completed, rawTranscription: "Rerun text")

        let row = try await stored()
        XCTAssertNil(row?.cleanupModel)
        XCTAssertNil(row?.cleanupError)
    }

    func testARerunStoresItsOwnTextAsTheOriginal() async throws {
        let info = try await notification {
            await store.updateRecordingProgressOnlySync(recording.id, transcription: "Send the mock-ups.",
                                                        progress: 1, status: .completed,
                                                        rawTranscription: "Send the mock-ups.")
        }

        let row = try await stored()
        XCTAssertEqual(row?.transcription, "Send the mock-ups.")
        XCTAssertEqual(row?.rawTranscription, "Send the mock-ups.")
        XCTAssertNil(row?.distinctOriginal, "nothing left to offer: the text is the engine's")
        XCTAssertEqual(info["rawTranscription"] as? String, "Send the mock-ups.")
    }

    func testAnUpdateWithoutAnOriginalKeepsTheOneStored() async throws {
        let info = try await notification {
            await store.updateRecordingProgressOnlySync(recording.id, transcription: "Send the mockups.",
                                                        progress: 0.5, status: .transcribing)
        }

        let row = try await stored()
        XCTAssertEqual(row?.rawTranscription, "um send the mock ups")
        XCTAssertNil(info["rawTranscription"])
    }

    /// A report on such a row says "same as before cleanup", not "not kept".
    func testAReportOnARerunHasTheSameTextBeforeCleanup() async throws {
        await store.updateRecordingProgressOnlySync(recording.id, transcription: "Rerun text", progress: 1,
                                                    status: .completed, rawTranscription: "Rerun text")
        let fetched = try await stored()
        let row = try XCTUnwrap(fetched)

        let report = TranscriptionReport(recording: row, problem: .other, languageSetting: nil, appDetails: "x")

        XCTAssertEqual(report.rawText, "Rerun text")
        XCTAssertNil(report.distinctRawText)
    }
}
