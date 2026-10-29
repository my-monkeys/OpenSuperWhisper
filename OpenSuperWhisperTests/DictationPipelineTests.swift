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
            return text
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
            return cleaned
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
}
