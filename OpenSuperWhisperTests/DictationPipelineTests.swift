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

    /// A temp clip that can actually be moved. The success and recovered paths publish it with
    /// the real recorder, so a path handed a URL that does not exist fails at the move and never
    /// reaches the branch under test.
    private func makeClip(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString).wav")
        try Data("RIFF".utf8).write(to: url)
        return url
    }

    private func recordingIDs() async -> Set<UUID> {
        Set(((try? await RecordingStore.shared.fetchRecordings(limit: 200, offset: 0)) ?? []).map(\.id))
    }

    /// The first row that was not there before the test enqueued its dictation.
    private func newRecording(after before: Set<UUID>, attempts: Int = 300) async -> Recording? {
        for _ in 0..<attempts {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if let row = (try? await RecordingStore.shared.fetchRecordings(limit: 200, offset: 0))?
                .first(where: { !before.contains($0.id) }) {
                return row
            }
        }
        return nil
    }

    /// All the rows that appeared since `before`, once there are at least `count` of them.
    private func newRecordings(after before: Set<UUID>, count: Int,
                               attempts: Int = 300) async -> [Recording] {
        for _ in 0..<attempts {
            try? await Task.sleep(nanoseconds: 10_000_000)
            let rows = ((try? await RecordingStore.shared.fetchRecordings(limit: 200, offset: 0)) ?? [])
                .filter { !before.contains($0.id) }
            if rows.count >= count { return rows }
        }
        return []
    }

    private func drain(_ pipeline: DictationPipeline, attempts: Int = 500) async {
        var waited = 0
        while pipeline.isProcessing && waited < attempts {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
    }

    /// The clock only advances where the test says so: every `uptime()` read in between costs
    /// nothing, so a stage delta is exactly what its override added. It also means an assertion
    /// never depends on how many times the pipeline happens to read the clock — a harmless
    /// refactor that adds a stamp cannot turn these values red.
    private func runClock(_ pipeline: DictationPipeline, _ clock: ClockBox) {
        pipeline.uptime = { clock.now }
    }

    private func resetSeams(_ pipeline: DictationPipeline) {
        pipeline.uptime = UptimeClock.now
        pipeline.transcribeOverride = nil
        pipeline.cleanupOverride = nil
        pipeline.deliverOverride = nil
        pipeline.agentReplyOverride = nil
        pipeline.moveOverride = nil
        pipeline.noticeOverride = nil
    }

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
            tempURL: try makeClip("osw-recovered"),
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

    /// The whole path through the real `process()`: every stage the dictation produced is on the
    /// row. Only `finalizeMs` and `machine` are seeds — the stop handler measures those and a
    /// pipeline test never runs it. Everything else has to come from a stamp, or the test passes
    /// against an instrument that recorded nothing.
    func testANormalDictationStampsEveryMeasuredStage() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        // On, because insertMs is measured only for text that actually went into a field (B3).
        prefs.autoPasteTranscription = true
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.appContextFormattingEnabled = false
        prefs.postRecordHookEnabled = false

        let pipeline = DictationPipeline.shared
        let clock = ClockBox()
        runClock(pipeline, clock)
        pipeline.transcribeOverride = { _, _ in
            clock.now += 50
            return "measured words"
        }
        pipeline.cleanupOverride = { text in CleanupOutcome(text: text, status: .notRun) }
        pipeline.deliverOverride = { _, _ in
            clock.now += 10
            return .inserted
        }
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        var seed = DictationTiming()
        seed.finalizeMs = 7
        seed.machine = MachineState(thermalState: "nominal", lowPowerMode: false, loadAverage1m: nil)
        pipeline.enqueue(tempURL: try makeClip("osw-timing-normal"), startedAt: Date(),
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(),
                         modelOption: nil, timing: seed, stoppedAtUptime: clock.now)
        await drain(pipeline)

        let saved = await newRecording(after: before)
        let row = try XCTUnwrap(saved)
        let timing = try XCTUnwrap(row.timing)
        XCTAssertEqual(timing.finalizeMs, 7, "the stop handler's stage survives the post-delivery re-encode")
        XCTAssertEqual(timing.queueWaitMs, 0)
        XCTAssertEqual(timing.transcribeMs, 50)
        XCTAssertEqual(timing.transcribeAttempts, 1)
        XCTAssertEqual(timing.insertMs, 10)
        XCTAssertEqual(timing.totalMs, 60, "stop press → insertion finished")
        XCTAssertNil(timing.cleanupMs, "no pass was due, so the stage did not run")
        XCTAssertNil(timing.engineWaitMs, "the engine split is not measured through a replaced engine")
        XCTAssertNil(timing.engineLoadMs)
        XCTAssertEqual(timing.machine?.thermalState, "nominal")

        RecordingStore.shared.deleteRecording(row)
    }

    /// A queued dictation waits behind the one in flight. The first run costs 50 on the scripted
    /// clock, so the second row's queue wait is exactly that — measured from its own enqueue.
    /// Every other timing test asserts `queueWaitMs == 0`, which a hardcoded zero would satisfy;
    /// this is the one that would redden it.
    func testAQueuedDictationMeasuresItsWaitBehindTheOneInFlight() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false

        let pipeline = DictationPipeline.shared
        let clock = ClockBox()
        runClock(pipeline, clock)
        pipeline.transcribeOverride = { url, _ in
            if url.lastPathComponent.contains("queue-first") { clock.now += 50 }
            return "text for \(url.lastPathComponent)"
        }
        pipeline.cleanupOverride = { text in CleanupOutcome(text: text, status: .notRun) }
        pipeline.deliverOverride = { _, _ in .inserted }
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        // Distinct start times give each row a stable identity; both are enqueued while the
        // clock is still 0, so nothing but the serial queue can explain a non-zero wait.
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_700_000_001)
        pipeline.enqueue(tempURL: try makeClip("osw-queue-first"), startedAt: firstDate,
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(),
                         modelOption: nil, stoppedAtUptime: clock.now)
        pipeline.enqueue(tempURL: try makeClip("osw-queue-second"), startedAt: secondDate,
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(),
                         modelOption: nil, stoppedAtUptime: clock.now)
        await drain(pipeline)

        let rows = await newRecordings(after: before, count: 2)
        let first = try XCTUnwrap(rows.first { $0.timestamp == firstDate })
        let second = try XCTUnwrap(rows.first { $0.timestamp == secondDate })
        XCTAssertEqual(first.timing?.queueWaitMs, 0, "nothing was ahead of it")
        XCTAssertEqual(second.timing?.queueWaitMs, 50, "it waited for the first run")
        XCTAssertEqual(second.timing?.transcribeMs, 0, "its own run was instant")

        for row in rows { RecordingStore.shared.deleteRecording(row) }
    }

    /// `insertMs` means text went into a field. Every delivery that put nothing there leaves it
    /// nil while the rest of the run is still measured (B3).
    func testInsertionIsMeasuredOnlyWhenTextActuallyWentIn() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false

        let pipeline = DictationPipeline.shared
        let clock = ClockBox()
        var notices: [RecordingState] = []
        runClock(pipeline, clock)
        pipeline.transcribeOverride = { _, _ in
            clock.now += 5
            return "some words"
        }
        pipeline.cleanupOverride = { text in CleanupOutcome(text: text, status: .notRun) }
        pipeline.noticeOverride = { notices.append($0) }
        defer { resetSeams(pipeline) }

        let cases: [(name: String, delivery: DictationPipeline.Delivery, autoPaste: Bool)] = [
            ("held", .held, true),
            ("on the clipboard", .onClipboardAnnounced, true),
            ("auto-paste off", .inserted, false),
        ]
        for (index, testCase) in cases.enumerated() {
            prefs.autoPasteTranscription = testCase.autoPaste
            pipeline.deliverOverride = { _, _ in testCase.delivery }

            let before = await recordingIDs()
            pipeline.enqueue(tempURL: try makeClip("osw-insert-\(index)"), startedAt: Date(),
                             streamedFallback: "", context: DictationPipeline.ContextSnapshot(),
                             modelOption: nil, stoppedAtUptime: clock.now)
            await drain(pipeline)

            let saved = await newRecording(after: before)
            let row = try XCTUnwrap(saved, testCase.name)
            let timing = try XCTUnwrap(row.timing)
            XCTAssertNil(timing.insertMs, "\(testCase.name): nothing was inserted")
            XCTAssertNotNil(timing.transcribeMs, "\(testCase.name): the run was still measured")

            RecordingStore.shared.deleteRecording(row)
        }
    }

    /// The stop press is the origin of the whole measurement, and the view model is where it is
    /// taken. The stop override costs 40 on the scripted clock, so a `stopMark` taken on the
    /// first line makes `finalizeMs` 40; taken after the recorder, it would be 0. Nothing else
    /// in the suite produces these two fields (M3).
    func testTheStopPressAndTheMachineAreMeasuredByTheStopHandler() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false

        let clip = try makeClip("osw-stop-mark")
        let pipeline = DictationPipeline.shared
        let clock = ClockBox()
        let viewModel = IndicatorViewModel()
        viewModel.uptime = { clock.now }
        viewModel.stopRecordingOverride = {
            clock.now += 40
            return .clip(clip)
        }
        runClock(pipeline, clock)
        pipeline.transcribeOverride = { _, _ in
            clock.now += 10
            return "measured from the stop"
        }
        pipeline.cleanupOverride = { text in CleanupOutcome(text: text, status: .notRun) }
        pipeline.deliverOverride = { _, _ in .inserted }
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        viewModel.startDecoding()
        await drain(pipeline)

        let saved = await newRecording(after: before)
        let row = try XCTUnwrap(saved)
        let timing = try XCTUnwrap(row.timing)
        XCTAssertEqual(timing.finalizeMs, 40, "stop press → the clip is on its way")
        XCTAssertNotNil(timing.machine, "the Mac at the stop instant")
        XCTAssertEqual(timing.transcribeMs, 10)
        XCTAssertEqual(timing.totalMs, 50, "stop press → insertion finished")

        RecordingStore.shared.deleteRecording(row)
    }

    /// A failure keeps what ran and leaves what never ran nil. The retry is part of the run, so
    /// both failed attempts are inside the span and counted.
    func testAFailedDictationWritesThePartialMeasurement() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false

        let pipeline = DictationPipeline.shared
        let clock = ClockBox()
        var notices: [RecordingState] = []
        runClock(pipeline, clock)
        pipeline.transcribeOverride = { _, _ in
            clock.now += 40
            throw MoveFailure()
        }
        pipeline.noticeOverride = { notices.append($0) }
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        var seed = DictationTiming()
        seed.finalizeMs = 7
        pipeline.enqueue(tempURL: try makeClip("osw-timing-failed"), startedAt: Date(),
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(),
                         modelOption: nil, timing: seed, stoppedAtUptime: clock.now)
        await drain(pipeline)

        let saved = await newRecording(after: before)
        let row = try XCTUnwrap(saved)
        XCTAssertEqual(row.status, .failed)
        let timing = try XCTUnwrap(row.timing)
        XCTAssertEqual(timing.finalizeMs, 7)
        XCTAssertEqual(timing.transcribeMs, 80, "both failed attempts are inside the span")
        XCTAssertEqual(timing.transcribeAttempts, 2)
        XCTAssertEqual(timing.totalMs, 80)
        XCTAssertNil(timing.cleanupMs, "the run never reached the cleanup")
        XCTAssertNil(timing.insertMs)
        XCTAssertNil(timing.engineWaitMs)
        XCTAssertEqual(notices.count, 2, "the retry notice and the failure notice went through the seam")

        RecordingStore.shared.deleteRecording(row)
    }

    /// A retried dictation is one dictation: the span covers both attempts and the count says so.
    /// Without the count a retry reads as a slow model in the filed report.
    func testARetryIsCountedAndTheSpanCoversBothAttempts() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        // On, so the zero here means "ran and cost nothing", not "did not run" (B3).
        prefs.autoPasteTranscription = true
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false

        let pipeline = DictationPipeline.shared
        let clock = ClockBox()
        var attempts = 0
        runClock(pipeline, clock)
        pipeline.transcribeOverride = { _, _ in
            attempts += 1
            if attempts == 1 {
                clock.now += 20
                throw MoveFailure()
            }
            clock.now += 30
            return "heard on the second try"
        }
        pipeline.noticeOverride = { _ in }
        pipeline.deliverOverride = { _, _ in .inserted }
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        pipeline.enqueue(tempURL: try makeClip("osw-timing-retry"), startedAt: Date(),
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(),
                         modelOption: nil, stoppedAtUptime: clock.now)
        await drain(pipeline)

        let saved = await newRecording(after: before)
        let row = try XCTUnwrap(saved)
        let timing = try XCTUnwrap(row.timing)
        XCTAssertEqual(timing.transcribeMs, 50, "the span covers both attempts")
        XCTAssertEqual(timing.transcribeAttempts, 2)
        XCTAssertEqual(timing.insertMs, 0, "it ran, and cost nothing on this clock")
        XCTAssertEqual(timing.totalMs, 50)

        RecordingStore.shared.deleteRecording(row)
    }

    /// An answer to a waiting agent runs through the cleanup and stops there: nothing is inserted
    /// into a field, so `insertMs` is nil and the hand-off is the terminal point.
    func testAnAgentReplyStampsCleanupAndLeavesInsertionUnmeasured() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = true
        prefs.postRecordHookEnabled = false

        let pipeline = DictationPipeline.shared
        let clock = ClockBox()
        var replies: [(text: String, id: String, send: Bool)] = []
        runClock(pipeline, clock)
        pipeline.transcribeOverride = { _, _ in
            clock.now += 30
            return "reply words"
        }
        pipeline.cleanupOverride = { text in
            clock.now += 15
            return CleanupOutcome(text: text, status: .cleaned(model: "m"))
        }
        pipeline.agentReplyOverride = { replies.append(($0, $1, $2)) }
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        var context = DictationPipeline.ContextSnapshot()
        context.agentReplyID = "request-1"
        pipeline.enqueue(tempURL: try makeClip("osw-timing-agent"), startedAt: Date(),
                         streamedFallback: "", context: context,
                         modelOption: nil, stoppedAtUptime: clock.now)
        await drain(pipeline)

        let saved = await newRecording(after: before)
        let row = try XCTUnwrap(saved)
        let timing = try XCTUnwrap(row.timing)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(timing.transcribeMs, 30)
        XCTAssertEqual(timing.cleanupMs, 15)
        XCTAssertNil(timing.insertMs, "nothing was inserted into a field")
        XCTAssertEqual(timing.totalMs, 45)

        RecordingStore.shared.deleteRecording(row)
    }

    /// A dictation with no words never reaches a row, so there is nowhere for a measurement to
    /// go. Adding one just to hold timing would be a history entry the user did not dictate.
    func testADictationWithNoSpeechWritesNoTimingRow() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false

        let pipeline = DictationPipeline.shared
        var notices: [RecordingState] = []
        pipeline.noticeOverride = { notices.append($0) }
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        pipeline.enqueue(tempURL: nil, startedAt: Date(), streamedFallback: "",
                         context: DictationPipeline.ContextSnapshot(), modelOption: nil)
        await drain(pipeline)

        let after = await recordingIDs()
        XCTAssertEqual(after, before, "nothing was measured, so nothing is written")
        XCTAssertFalse(notices.isEmpty, "the no-speech notice went through the seam, not a panel")
    }

    /// History off means no row at all, so there is nowhere for a measurement to land — and the
    /// feature must not write one just to hold timings (path 3 of the write-path matrix).
    func testADictationWithHistoryOffWritesNoTimingRow() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = false
        prefs.autoPasteTranscription = true
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false
        prefs.postRecordHookEnabled = false

        let pipeline = DictationPipeline.shared
        let clock = ClockBox()
        runClock(pipeline, clock)
        pipeline.transcribeOverride = { _, _ in
            clock.now += 10
            return "words with no history"
        }
        pipeline.cleanupOverride = { text in CleanupOutcome(text: text, status: .notRun) }
        pipeline.deliverOverride = { _, _ in .inserted }
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        pipeline.enqueue(tempURL: try makeClip("osw-history-off"), startedAt: Date(),
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(),
                         modelOption: nil, stoppedAtUptime: clock.now)
        await drain(pipeline)

        let after = await recordingIDs()
        XCTAssertEqual(after, before, "no row, so nothing may try to persist a timing")
    }

    /// A discard that lands before the loop dequeues anything: there is no run to measure, and
    /// nothing is persisted. The in-flight case is the next test — this one would pass even if
    /// the in-flight check were missing, which is why it is not the only one.
    func testADiscardBeforeTheLoopStartsWritesNothing() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false

        let pipeline = DictationPipeline.shared
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        pipeline.enqueue(tempURL: try makeClip("osw-timing-discard"), startedAt: Date(),
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(),
                         modelOption: nil)
        pipeline.discardEverything()
        await drain(pipeline)

        let after = await recordingIDs()
        XCTAssertEqual(after, before, "a thrown-away dictation is not persisted")
    }

    /// A discard that lands while the clip is already being transcribed: the run returns its
    /// text, finds the dictation thrown away, and must not persist a row or a measurement. The
    /// continuation holds the run open until the discard has been applied, so this exercises
    /// the success branch's discard check rather than the queue-emptying one.
    func testAnInFlightDiscardWritesNoTimingRow() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        prefs.autoPasteTranscription = false
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = false

        let pipeline = DictationPipeline.shared
        var release: CheckedContinuation<Void, Never>?
        pipeline.transcribeOverride = { _, _ in
            await withCheckedContinuation { release = $0 }
            return "words nobody kept"
        }
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        pipeline.enqueue(tempURL: try makeClip("osw-timing-discard-inflight"), startedAt: Date(),
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(),
                         modelOption: nil)
        var waited = 0
        while release == nil && waited < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        let resume = try XCTUnwrap(release, "the run should reach the engine")
        pipeline.discardEverything()
        resume.resume()
        await drain(pipeline)

        let after = await recordingIDs()
        XCTAssertEqual(after, before, "a dictation thrown away mid-run is not persisted")
    }

    /// The engine split may only be claimed when the real engine ran. Pure, because the
    /// process-wide snapshot happens to be nil in a fresh test process — the pipeline-level
    /// `engineWaitMs == nil` assertion would stay green with the guard removed (M7).
    func testEngineSplitIsClaimedOnlyForTheRealEngine() {
        let run = TranscriptionService.RunTimings(engineWaitMs: 0, engineLoadMs: 2_100, runMs: 1_200)

        XCTAssertNil(DictationPipeline.engineSplit(replacedEngine: true, lastRun: run),
                     "a replaced engine's snapshot describes another run")
        XCTAssertEqual(DictationPipeline.engineSplit(replacedEngine: false, lastRun: run), run)
        XCTAssertNil(DictationPipeline.engineSplit(replacedEngine: false, lastRun: nil),
                     "no run, no split")
    }

    /// The one real-clock test. Bounds only: every stage non-negative, and the total at least as
    /// large as each of them. The stop instant comes from the SAME clock the pipeline reads,
    /// immediately before the enqueue, which makes the comparison an invariant rather than an
    /// accident of two clocks. No upper bound — a loaded CI runner would flake.
    func testRealClockStagesAreNonNegativeAndTheTotalCoversThem() async throws {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.saveTranscriptionHistory = true
        // On, so the insertion stage is part of the bounds check (B3).
        prefs.autoPasteTranscription = true
        prefs.autoCopyToClipboard = false
        prefs.aiPostProcessingEnabled = true
        prefs.postRecordHookEnabled = false

        let pipeline = DictationPipeline.shared
        pipeline.uptime = UptimeClock.now
        pipeline.transcribeOverride = { _, _ in "bounds words" }
        pipeline.cleanupOverride = { text in CleanupOutcome(text: text, status: .cleaned(model: "m")) }
        pipeline.deliverOverride = { _, _ in .inserted }
        defer { resetSeams(pipeline) }

        let before = await recordingIDs()
        pipeline.enqueue(tempURL: try makeClip("osw-timing-bounds"), startedAt: Date(),
                         streamedFallback: "", context: DictationPipeline.ContextSnapshot(),
                         modelOption: nil, stoppedAtUptime: UptimeClock.now)
        await drain(pipeline)

        let saved = await newRecording(after: before)
        let row = try XCTUnwrap(saved)
        let timing = try XCTUnwrap(row.timing)
        let total = try XCTUnwrap(timing.totalMs)
        let stages = [timing.queueWaitMs, timing.cleanupMs, timing.transcribeMs, timing.insertMs]
            .compactMap { $0 }
        XCTAssertFalse(stages.isEmpty, "the path under test measured something")
        for stage in stages {
            XCTAssertGreaterThanOrEqual(stage, 0)
            XCTAssertLessThanOrEqual(stage, total, "\(stage) ms must be inside the total")
        }

        RecordingStore.shared.deleteRecording(row)
    }
}
