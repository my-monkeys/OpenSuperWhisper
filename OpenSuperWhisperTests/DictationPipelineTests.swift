//
//  DictationPipelineTests.swift
//  OpenSuperWhisperTests
//
//  Covers the parallel-recording pipeline: the shared engine gate serializes transcriptions
//  (so the non-thread-safe whisper context is never hit twice at once), and the DictationPipeline
//  drains clips in recording-start order while tracking how many are still pending.
//

import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

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

    private final class PhaseRun { var duringFilePass: Bool?; var duringCleanup: Bool?; var processingInCleanup: Bool? }

    /// `isTranscribing` covers the clip's wait and file pass, not the cleanup model after it: a
    /// dictation started while the previous one is only being cleaned up still gets its live
    /// preview (#250).
    func testIsTranscribingCoversTheFilePassButNotTheCleanup() async {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = false
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false

        let pipeline = DictationPipeline.shared
        let run = PhaseRun()
        pipeline.transcribeOverride = { _, _ in
            run.duringFilePass = pipeline.isTranscribing
            return "heard"
        }
        pipeline.cleanupOverride = { text in
            run.duringCleanup = pipeline.isTranscribing
            run.processingInCleanup = pipeline.isProcessing
            return CleanupOutcome(text: text, status: .notRun)
        }
        pipeline.deliverOverride = { _, _ in .inserted }
        defer {
            pipeline.transcribeOverride = nil
            pipeline.cleanupOverride = nil
            pipeline.deliverOverride = nil
        }

        pipeline.enqueue(tempURL: URL(fileURLWithPath: "/tmp/osw-pipeline-phase.wav"), startedAt: Date(),
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(), modelOption: nil)
        XCTAssertTrue(pipeline.isTranscribing, "a queued clip is still waiting for the engine")
        var waited = 0
        while pipeline.isProcessing && waited < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }

        XCTAssertEqual(run.duringFilePass, true)
        XCTAssertEqual(run.duringCleanup, false)
        XCTAssertEqual(run.processingInCleanup, true, "the cleanup is still part of processing")
        XCTAssertFalse(pipeline.isTranscribing)
    }

    private final class StageRun { var cleaningUpDuringPass: Bool?; var cleaningUpDuringFilePass: Bool? }

    /// The bubble says "Cleaning up…" only while the model is working (#269), and a pass that
    /// worked clears the failure the Settings were showing (#264).
    func testTheCleanupStageIsPublishedOnlyWhileTheModelRuns() async {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = false
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = true
        CleanupSessionStatus.shared.record(CleanupOutcome(text: "", status: .failed(model: "m", reason: "boom")))

        let pipeline = DictationPipeline.shared
        let run = StageRun()
        pipeline.transcribeOverride = { _, _ in
            run.cleaningUpDuringFilePass = pipeline.isCleaningUp
            return "heard"
        }
        pipeline.cleanupOverride = { text in
            run.cleaningUpDuringPass = pipeline.isCleaningUp
            return CleanupOutcome(text: text, status: .cleaned(model: "m"))
        }
        pipeline.deliverOverride = { _, _ in .inserted }
        defer {
            pipeline.transcribeOverride = nil
            pipeline.cleanupOverride = nil
            pipeline.deliverOverride = nil
        }

        pipeline.enqueue(tempURL: URL(fileURLWithPath: "/tmp/osw-pipeline-stage.wav"), startedAt: Date(),
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(), modelOption: nil)
        var waited = 0
        while pipeline.isProcessing && waited < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }

        XCTAssertEqual(run.cleaningUpDuringFilePass, false)
        XCTAssertEqual(run.cleaningUpDuringPass, true)
        XCTAssertFalse(pipeline.isCleaningUp)
        XCTAssertNil(CleanupSessionStatus.shared.lastFailure, "a pass that worked clears the failure")
    }

    /// A dictation the recorder never captured, rescued from the live preview. The tap and the
    /// recorder are separate consumers of the microphone, so one can come back empty while the
    /// other heard everything, and the words should not be thrown away for want of a file (#128).
    func testADictationWithNoClipIsCarriedByItsLivePreview() async {
        let prefs = AppPreferences.shared
        let savedHistory = prefs.saveTranscriptionHistory
        let savedPaste = prefs.autoPasteTranscription
        let savedCopy = prefs.autoCopyToClipboard
        let savedAI = prefs.aiPostProcessingEnabled
        let savedHook = prefs.postRecordHookEnabled
        prefs.saveTranscriptionHistory = false
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false
        defer {
            prefs.saveTranscriptionHistory = savedHistory
            prefs.autoPasteTranscription = savedPaste
            prefs.autoCopyToClipboard = savedCopy
            prefs.aiPostProcessingEnabled = savedAI
            prefs.postRecordHookEnabled = savedHook
        }

        let pipeline = DictationPipeline.shared
        let box = OrderBox()
        // The engine must never be asked to transcribe: there is no file to hand it.
        pipeline.transcribeOverride = { url, _ in
            box.order.append(url.lastPathComponent)
            return "the engine should not have run"
        }
        defer { pipeline.transcribeOverride = nil }

        pipeline.enqueue(
            tempURL: nil,
            startedAt: Date(),
            streamedFallback: "the bonfire was Bunny's idea",
            context: DictationPipeline.ContextSnapshot(),
            modelOption: nil)

        var waited = 0
        while pipeline.isProcessing && waited < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }

        XCTAssertFalse(pipeline.isProcessing, "a clip-less dictation must still drain")
        XCTAssertEqual(box.order, [], "nothing to transcribe means the engine is not called")
        XCTAssertEqual(pipeline.pendingCount, 0)
    }

    // MARK: - Snippets (#167)

    private final class SnippetRun {
        var cleanupSaw: [String] = []
        var inserted: [String] = []
        var agentReplies: [(text: String, id: String, send: Bool)] = []
    }

    /// Runs one dictation whose engine heard `heard` and whose cleanup model returns `cleaned`,
    /// with snippets on and every side effect replaced: no history, no paste, no Return, no hook.
    private func runSnippetDictation(heard: String, cleaned: String,
                                     agentReplyID: String? = nil) async -> SnippetRun {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = false
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.submitOnVoiceCommand = true
        prefs.snippets = [Snippet(trigger: "sign off", expansion: "Best,\nMax")]

        let pipeline = DictationPipeline.shared
        let run = SnippetRun()
        pipeline.transcribeOverride = { _, _ in heard }
        pipeline.cleanupOverride = { text in
            run.cleanupSaw.append(text)
            return CleanupOutcome(text: cleaned, status: .notRun)
        }
        pipeline.agentReplyOverride = { run.agentReplies.append(($0, $1, $2)) }
        pipeline.deliverOverride = { text, _ in
            run.inserted.append(text)
            return .inserted
        }
        defer {
            pipeline.transcribeOverride = nil
            pipeline.cleanupOverride = nil
            pipeline.agentReplyOverride = nil
            pipeline.deliverOverride = nil
        }

        var context = DictationPipeline.ContextSnapshot()
        context.agentReplyID = agentReplyID
        pipeline.enqueue(tempURL: URL(fileURLWithPath: "/tmp/osw-pipeline-snippet.wav"), startedAt: Date(),
                         streamedFallback: "", context: context, modelOption: nil)
        var waited = 0
        while pipeline.isProcessing && waited < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        return run
    }

    /// The cleanup model sees the trigger, never the snippet's text, and the expansion is made
    /// on what it returned once "press enter" is off the end.
    func testASnippetIsExpandedAfterTheCleanupModelAndTheSubmitCommand() async {
        let run = await runSnippetDictation(heard: "thanks sign off press enter",
                                            cleaned: "Thanks. Sign off. Press enter.")
        XCTAssertEqual(run.cleanupSaw, ["thanks sign off press enter"])
        XCTAssertEqual(run.inserted, ["Thanks. Best,\nMax"])
        XCTAssertTrue(run.agentReplies.isEmpty)
    }

    func testAnAgentReplyGetsTheExpandedText() async {
        let run = await runSnippetDictation(heard: "sign off press enter",
                                            cleaned: "Sign off. Press enter.", agentReplyID: "request-1")
        XCTAssertEqual(run.cleanupSaw, ["sign off press enter"])
        XCTAssertEqual(run.agentReplies.map(\.text), ["Best,\nMax"])
        XCTAssertEqual(run.agentReplies.map(\.id), ["request-1"])
        XCTAssertEqual(run.agentReplies.map(\.send), [true], "the spoken submit still sends the reply")
        XCTAssertTrue(run.inserted.isEmpty)
    }

    // MARK: - Timing (#262)

    private final class ClockBox { var now: UInt64 = 0 }
    private struct MoveFailure: Error {}

    /// A throw AFTER the transcribe block must keep the span that block already measured: the
    /// catch fills only what the run never recorded. Unguarded, the value would absorb the move
    /// that failed, and the engine split would be re-read after an await, when it can belong to
    /// another run.
    ///
    /// `moveOverride` throws where the recorder would publish the clip. The failure path keeps
    /// the real recorder, so the clip is still saved and the `.failed` row is there to inspect.
    func testAFailureAfterTranscriptionKeepsTheMeasuredSpan() async throws {
        let scratch = ScratchPreferences()
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false

        let pipeline = DictationPipeline.shared
        let clock = ClockBox()
        pipeline.uptime = { clock.now }
        pipeline.transcribeOverride = { _, _ in
            clock.now += 50
            return "hello there"
        }
        pipeline.moveOverride = { _, _ in
            clock.now += 500
            throw MoveFailure()
        }
        // The catch would otherwise build an indicator panel in the test process.
        pipeline.noticeOverride = { _ in }
        defer {
            pipeline.uptime = UptimeClock.now
            pipeline.transcribeOverride = nil
            pipeline.moveOverride = nil
            pipeline.noticeOverride = nil
            scratch.restore()
        }

        let before = Set(try await RecordingStore.shared.fetchRecordings(limit: 200, offset: 0).map(\.id))
        let clip = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osw-timing-\(UUID().uuidString).wav")
        try Data("RIFF".utf8).write(to: clip)
        pipeline.enqueue(tempURL: clip, startedAt: Date(), streamedFallback: "",
                         context: DictationPipeline.ContextSnapshot(), modelOption: nil)

        var saved: Recording?
        for _ in 0..<300 where saved == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            saved = try await RecordingStore.shared.fetchRecordings(limit: 200, offset: 0)
                .first { !before.contains($0.id) }
        }
        let row = try XCTUnwrap(saved)
        let timing = try XCTUnwrap(row.timing)

        XCTAssertEqual(timing.transcribeMs, 50, "the span must not absorb the step that failed")
        XCTAssertEqual(timing.transcribeAttempts, 1)
        XCTAssertNil(timing.engineWaitMs, "never a split from another run")
        XCTAssertNil(timing.engineLoadMs)

        RecordingStore.shared.deleteRecording(row)
    }

    /// The recovered-clip path writes its measurement too, and its queue wait and total come from
    /// the enqueue: the clip's own date can be days old (#262).
    ///
    /// The insert is awaited, so the hand-off's post-delivery UPDATE always finds the row — the
    /// `totalMs` assertion is the one that would go missing if the UPDATE overtook the INSERT.
    func testARecoveredClipWritesItsTotal() async throws {
        let scratch = ScratchPreferences()
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false

        let pipeline = DictationPipeline.shared
        let clock = ClockBox()
        pipeline.uptime = { clock.now }
        pipeline.transcribeOverride = { _, _ in
            clock.now += 10
            return "recovered words"
        }
        let recovered = OrderBox()
        defer {
            pipeline.uptime = UptimeClock.now
            pipeline.transcribeOverride = nil
            scratch.restore()
        }

        let before = Set(try await RecordingStore.shared.fetchRecordings(limit: 200, offset: 0).map(\.id))
        pipeline.enqueue(
            tempURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("osw-recovered-\(UUID().uuidString).wav"),
            startedAt: Date().addingTimeInterval(-2 * 24 * 3600),
            streamedFallback: "",
            context: DictationPipeline.ContextSnapshot(),
            modelOption: nil,
            onRecovered: { recovered.order.append($0) })

        var saved: Recording?
        for _ in 0..<300 where saved == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            saved = try await RecordingStore.shared.fetchRecordings(limit: 200, offset: 0)
                .first { !before.contains($0.id) }
        }
        let row = try XCTUnwrap(saved)
        let timing = try XCTUnwrap(row.timing)

        XCTAssertEqual(recovered.order, ["recovered words"])
        XCTAssertEqual(timing.queueWaitMs, 0, "measured from the enqueue, never from the clip's own date")
        XCTAssertEqual(timing.totalMs, 10, "the hand-off is this dictation's terminal point")
        XCTAssertNil(timing.finalizeMs, "there was no stop press")
        XCTAssertNil(timing.insertMs, "nothing was inserted into a field")

        RecordingStore.shared.deleteRecording(row)
    }
}
