import XCTest

@testable import OpenSuperWhisperCore

/// The remote local-fallback builds and initializes a second engine. That cold load is time the
/// user waits after the server failed, and it used to be reported as the first engine's load
/// instead (B4). Driven through the real `transcribeAudio`: a stub remote engine fails the way
/// the fallback is meant for, and a stub fallback engine's load costs a known amount on the
/// scripted clock — so the asserted value can only come from the fallback branch.
final class TranscriptionServiceFallbackTimingTests: CoreTestCase {

    /// Nanoseconds, like `UptimeClock`, whose `milliseconds(from:to:)` divides by 1_000_000.
    /// `advance(ms:)` is the only way to move it.
    private final class ClockBox {
        /// Read-only, so `clock.now += n` cannot compile: milliseconds go through `advance(ms:)`.
        var now: UInt64 { nanoseconds }
        private var nanoseconds: UInt64 = 0
        func advance(ms: Int) { nanoseconds += UInt64(ms) * 1_000_000 }
    }

    private final class RemoteEngineThatFails: TranscriptionEngine {
        let clock: ClockBox
        let engineName = "Remote"
        let isModelLoaded = true

        init(clock: ClockBox) { self.clock = clock }

        func initialize() async throws { clock.advance(ms: 2) }
        func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String {
            throw RemoteError.network(nil)
        }
        func cancelTranscription() {}
        func getSupportedLanguages() -> [String] { [] }
    }

    private final class LocalEngineThatWorks: TranscriptionEngine {
        let clock: ClockBox
        let engineName = "Local"
        let isModelLoaded = true

        init(clock: ClockBox) { self.clock = clock }

        func initialize() async throws { clock.advance(ms: 7) }
        func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String {
            "from the fallback"
        }
        func cancelTranscription() {}
        func getSupportedLanguages() -> [String] { [] }
    }

    @MainActor
    func testTheFallbackEnginesLoadIsMeasured() async throws {
        let preferences = CoreTestEnvironment.preferences
        preferences.selectedEngine = "remote"
        preferences.remoteFallbackEnabled = true
        preferences.remoteFallbackModel = DictationModelOption(engine: "whisper",
                                                               identifier: "/models/fallback.bin",
                                                               displayName: "Fallback")

        let clock = ClockBox()
        let service = TranscriptionService(engineBuilder: { _ in RemoteEngineThatFails(clock: clock) })
        service.fallbackEngineBuilder = { _ in LocalEngineThatWorks(clock: clock) }
        service.uptime = { clock.now }

        let text = try await service.transcribeAudio(url: Fixtures.jfkWav,
                                                     settings: Fixtures.pinnedSettings())

        XCTAssertEqual(text, "from the fallback")
        XCTAssertTrue(service.lastUsedFallback)
        // The remote engine's load cost 2 ms and the fallback's 7. The run must report the
        // fallback's: that is the cold load the user paid for after the server failed.
        XCTAssertEqual(service.lastRunTimings?.engineLoadMs, 7)
    }
}
