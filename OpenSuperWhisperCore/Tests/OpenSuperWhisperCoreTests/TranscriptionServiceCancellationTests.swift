import XCTest
@testable import OpenSuperWhisperCore

/// A cancel belongs to one operation. It used to abort whatever held the engine gate, so a file
/// being dropped could cancel the dictation running at that moment, which then failed and was
/// retried; and a cancelled run came back as a failure rather than a cancellation.
final class TranscriptionServiceCancellationTests: CoreTestCase {

    /// Holds every run open until `release()` or its own `cancelTranscription()`.
    private final class HeldEngine: TranscriptionEngine, @unchecked Sendable {
        let engineName = "Held"
        let isModelLoaded = true
        private let lock = NSLock()
        private var open = true
        private var started = 0
        private var cancelled = 0

        var startCount: Int { lock.withLock { started } }
        var cancelCount: Int { lock.withLock { cancelled } }

        func release() { lock.withLock { open = false } }
        func initialize() async throws {}
        func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String {
            lock.withLock { started += 1 }
            while lock.withLock({ open }) { try await Task.sleep(nanoseconds: 5_000_000) }
            return "text"
        }
        func cancelTranscription() { lock.withLock { cancelled += 1; open = false } }
        func getSupportedLanguages() -> [String] { [] }
    }

    @MainActor
    private func makeService(_ engine: HeldEngine) -> TranscriptionService {
        let preferences = CoreTestEnvironment.preferences
        preferences.selectedEngine = "whisper"
        preferences.selectedWhisperModelPath = "/models/ggml-stub.bin"
        return TranscriptionService(engineBuilder: { _ in engine })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out")
    }

    @MainActor
    func testCancellingAnotherOperationLeavesTheRunAlone() async throws {
        let engine = HeldEngine()
        let service = makeService(engine)
        let run = Task { try await service.transcribeAudio(url: Fixtures.jfkWav, settings: Fixtures.pinnedSettings()) }
        try await waitUntil { engine.startCount == 1 }

        service.cancelTranscription(operation: UUID())
        engine.release()

        let text = try await run.value
        XCTAssertEqual(text, "text")
        XCTAssertEqual(engine.cancelCount, 0, "somebody else's cancel must not reach the engine")
    }

    @MainActor
    func testCancellingTheRunsOwnOperationSurfacesAsCancellation() async throws {
        let engine = HeldEngine()
        let service = makeService(engine)
        let operation = UUID()
        let run = Task {
            try await service.transcribeAudio(url: Fixtures.jfkWav, settings: Fixtures.pinnedSettings(),
                                              operation: operation)
        }
        try await waitUntil { engine.startCount == 1 }

        service.cancelTranscription(operation: operation)

        do {
            _ = try await run.value
            XCTFail("a cancelled run returns nothing")
        } catch is CancellationError {
        } catch {
            XCTFail("cancellation must not be reported as a failure: \(error)")
        }
        XCTAssertEqual(engine.cancelCount, 1)
    }

    @MainActor
    func testACancelledRunStillWaitingForTheGateNeverStartsTheEngine() async throws {
        let engine = HeldEngine()
        let service = makeService(engine)
        let holder = Task { try await service.transcribeAudio(url: Fixtures.jfkWav, settings: Fixtures.pinnedSettings()) }
        try await waitUntil { engine.startCount == 1 }
        let waiting = UUID()
        let waiter = Task {
            try await service.transcribeAudio(url: Fixtures.jfkWav, settings: Fixtures.pinnedSettings(),
                                              operation: waiting)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        service.cancelTranscription(operation: waiting)
        engine.release()

        let held = try await holder.value
        XCTAssertEqual(held, "text", "the run holding the gate is not the one cancelled")
        do {
            _ = try await waiter.value
            XCTFail("the cancelled waiter must not run")
        } catch is CancellationError {
        }
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.cancelCount, 0)
    }
}
