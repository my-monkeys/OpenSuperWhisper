import XCTest
@testable import OpenSuperWhisperCore

/// The engine split (#262): what one run spent waiting for the gate, loading the model, and
/// transcribing. Driven through the real `transcribeAudio` with a stub engine, because a
/// pipeline-level seam would replace the producer and prove nothing.
final class TranscriptionServiceRunTimingsTests: CoreTestCase {

    private final class StubEngine: TranscriptionEngine {
        let transcript: String
        let engineName = "Stub"
        let isModelLoaded = true

        init(transcript: String) {
            self.transcript = transcript
        }

        func initialize() async throws {}
        func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String { transcript }
        func cancelTranscription() {}
        func getSupportedLanguages() -> [String] { [] }
    }

    @MainActor
    private func service(transcript: String = "hello") -> TranscriptionService {
        let preferences = CoreTestEnvironment.preferences
        preferences.selectedEngine = "whisper"
        preferences.selectedWhisperModelPath = "/models/ggml-stub.bin"
        return TranscriptionService(engineBuilder: { _ in StubEngine(transcript: transcript) })
    }

    // MARK: - Real clock

    @MainActor
    func testARunPublishesItsTimings() async throws {
        let service = service()

        _ = try await service.transcribeAudio(url: Fixtures.jfkWav, settings: Fixtures.pinnedSettings())

        let timings = try XCTUnwrap(service.lastRunTimings)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(timings.engineWaitMs), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(timings.engineLoadMs), 0)
    }

    /// A second run still measures its load stage even though the engine is already up: 0 is a
    /// measurement, nil would mean the stage never ran. Bounds only — a real clock must never be
    /// asserted against an upper bound.
    @MainActor
    func testASecondRunStillMeasuresTheLoadStage() async throws {
        let service = service()
        _ = try await service.transcribeAudio(url: Fixtures.jfkWav, settings: Fixtures.pinnedSettings())

        _ = try await service.transcribeAudio(url: Fixtures.jfkWav, settings: Fixtures.pinnedSettings())

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(service.lastRunTimings?.engineLoadMs), 0)
    }

    // MARK: - Scripted clock

    /// Four stamps, in order: gate start, gate end, load start, load end. A millisecond per
    /// stamp makes each stage's arithmetic checkable by hand. The assertions are the values the
    /// stages produced, not the number of clock reads: an extra read outside a measured window
    /// is harmless, while a stage that stops measuring still reddens its own delta.
    @MainActor
    func testEveryStageIsMeasuredWithTheClock() async throws {
        let service = service()
        var stamps: UInt64 = 0
        service.uptime = {
            stamps += 1
            return stamps * 1_000_000
        }

        let text = try await service.transcribeAudio(url: Fixtures.jfkWav,
                                                     settings: Fixtures.pinnedSettings())

        let timings = try XCTUnwrap(service.lastRunTimings)
        XCTAssertEqual(timings.engineWaitMs, 1, "gate start 0 → gate end 1")
        XCTAssertEqual(timings.engineLoadMs, 1, "load start 2 → load end 3")
        XCTAssertEqual(text, "hello", "the run itself completed, not just its measurements")
    }
}
