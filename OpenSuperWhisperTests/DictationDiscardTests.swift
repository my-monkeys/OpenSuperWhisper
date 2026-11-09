//
//  DictationDiscardTests.swift
//  OpenSuperWhisperTests
//
//  A dictation the user threw away must leave nothing behind, wherever the discard lands:
//  a cancelled engine run is not a failure, and the cleanup pass and the row write come after
//  the one check that used to be there.
//

import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

@MainActor
final class DictationDiscardTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private let pipeline = DictationPipeline.shared

    override func setUp() async throws {
        scratch = ScratchPreferences()
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false
    }

    override func tearDown() async throws {
        pipeline.transcribeOverride = nil
        pipeline.cleanupOverride = nil
        pipeline.deliverOverride = nil
        pipeline.noticeOverride = nil
        scratch.restore()
    }

    private func makeClip() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osw-discard-\(UUID().uuidString).wav")
        try Data("RIFF".utf8).write(to: url)
        return url
    }

    private func recordingIDs() async -> Set<UUID> {
        Set(((try? await RecordingStore.shared.fetchRecordings(limit: 200, offset: 0)) ?? []).map(\.id))
    }

    private func runDiscardedDictation() async throws -> (rows: Set<UUID>, before: Set<UUID>, clip: URL) {
        let clip = try makeClip()
        let before = await recordingIDs()
        pipeline.enqueue(tempURL: clip, startedAt: Date(), streamedFallback: "",
                         context: DictationPipeline.ContextSnapshot(), modelOption: nil)
        for _ in 0..<500 where pipeline.isProcessing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return (await recordingIDs(), before, clip)
    }

    func testACancelledRunIsNeitherSavedAsFailedNorAnnounced() async throws {
        var notices: [RecordingState] = []
        pipeline.noticeOverride = { notices.append($0) }
        pipeline.transcribeOverride = { [pipeline] _, _ in
            pipeline.discardEverything()
            throw CancellationError()
        }

        let run = try await runDiscardedDictation()

        XCTAssertEqual(run.rows, run.before, "no failed row for a dictation the user cancelled")
        XCTAssertTrue(notices.isEmpty, "and no \"Transcription failed\" notice")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.clip.path), "the clip is dropped")
    }

    func testADiscardDuringCleanupSavesAndInsertsNothing() async throws {
        var inserted: [String] = []
        pipeline.transcribeOverride = { _, _ in "words nobody kept" }
        pipeline.cleanupOverride = { [pipeline] text in
            pipeline.discardEverything()
            return CleanupOutcome(text: text, status: .notRun)
        }
        pipeline.deliverOverride = { text, _ in
            inserted.append(text)
            return .inserted
        }

        let run = try await runDiscardedDictation()

        XCTAssertEqual(run.rows, run.before, "the row is not written after the discard")
        XCTAssertTrue(inserted.isEmpty, "and the text never reaches the document")
    }
}
