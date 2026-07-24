//
//  DictationPipelineTests.swift
//  OpenSuperWhisperTests
//
//  Covers the parallel-recording pipeline: the shared engine gate serializes transcriptions
//  (so the non-thread-safe whisper context is never hit twice at once), and the DictationPipeline
//  drains clips in recording-start order while tracking how many are still pending.
//

import XCTest
@testable import WhisperCore
@testable import OpenSuperWhisper

final class AsyncSemaphoreTests: XCTestCase {

    /// A 1-permit semaphore must never let two holders through at once — the core of the
    /// serialization fix. A naive actor (relying on reentrancy) would fail this.
    func testOnePermitAllowsOnlyOneHolderAtATime() async {
        let sem = AsyncSemaphore(1)

        actor Tracker {
            private(set) var maxActive = 0
            private var active = 0
            func enter() { active += 1; maxActive = max(maxActive, active) }
            func leave() { active -= 1 }
        }
        let tracker = Tracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await sem.wait()
                    await tracker.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await tracker.leave()
                    await sem.signal()
                }
            }
        }

        let maxActive = await tracker.maxActive
        XCTAssertEqual(maxActive, 1, "the 1-permit semaphore must serialize to a single holder")
    }

    /// Two permits should allow up to two concurrent holders (sanity check that it's a real
    /// counting semaphore, not an accidental hard mutex).
    func testTwoPermitsAllowTwoConcurrentHolders() async {
        let sem = AsyncSemaphore(2)

        actor Tracker {
            private(set) var maxActive = 0
            private var active = 0
            func enter() { active += 1; maxActive = max(maxActive, active) }
            func leave() { active -= 1 }
        }
        let tracker = Tracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await sem.wait()
                    await tracker.enter()
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    await tracker.leave()
                    await sem.signal()
                }
            }
        }

        let maxActive = await tracker.maxActive
        XCTAssertEqual(maxActive, 2, "two permits should allow exactly two concurrent holders")
    }
}

@MainActor
final class DictationPipelineTests: XCTestCase {

    private final class OrderBox { var order: [String] = [] }

    /// Enqueued clips are transcribed strictly in recording-start (FIFO) order, and `pendingCount`
    /// reflects the backlog: full right after enqueue, zero once drained.
    func testProcessesInRecordingStartOrderAndTracksPendingCount() async {
        let prefs = AppPreferences.shared
        let savedHistory = prefs.saveTranscriptionHistory
        let savedPaste = prefs.autoPasteTranscription
        let savedCopy = prefs.autoCopyToClipboard
        let savedAI = prefs.aiPostProcessingEnabled
        // Keep process() side-effect-free: no DB write, no synthetic paste, no LLM network call.
        prefs.saveTranscriptionHistory = false
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        defer {
            prefs.saveTranscriptionHistory = savedHistory
            prefs.autoPasteTranscription = savedPaste
            prefs.autoCopyToClipboard = savedCopy
            prefs.aiPostProcessingEnabled = savedAI
        }

        let pipeline = DictationPipeline.shared
        let box = OrderBox()
        pipeline.transcribeOverride = { url, _ in
            box.order.append(url.lastPathComponent)
            return "text for \(url.lastPathComponent)"
        }
        defer { pipeline.transcribeOverride = nil }

        for i in 0..<3 {
            pipeline.enqueue(
                tempURL: URL(fileURLWithPath: "/tmp/osw-pipeline-test-\(i).wav"),
                startedAt: Date(),
                streamedFallback: "",
                context: DictationPipeline.ContextSnapshot(),
                modelOption: nil)
        }
        // enqueue is synchronous and the drain loop only runs once we await below, so the whole
        // backlog is visible here.
        XCTAssertEqual(pipeline.pendingCount, 3)

        var waited = 0
        while pipeline.isProcessing && waited < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }

        XCTAssertFalse(pipeline.isProcessing, "pipeline should finish draining the queue")
        XCTAssertEqual(box.order,
                       ["osw-pipeline-test-0.wav", "osw-pipeline-test-1.wav", "osw-pipeline-test-2.wav"],
                       "clips must be transcribed in recording-start order")
        XCTAssertEqual(pipeline.pendingCount, 0, "pendingCount returns to zero once drained")
    }
}
