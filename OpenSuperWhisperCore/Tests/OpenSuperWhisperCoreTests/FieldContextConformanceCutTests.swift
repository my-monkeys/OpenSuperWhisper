import XCTest
@testable import OpenSuperWhisperCore

/// The conformance cut, executed (#89).
///
/// The capability table is a claim about engines, the structural scan reads source text, and the
/// body sentinels only see what a request builder was handed. None of them runs the dispatch that
/// decides whether an engine is handed the field at all — so `resolveFieldContext` could return
/// `.prose` for every engine and every other suite would stay green.
///
/// These tests drive `TranscriptionService` through its `engineBuilder` seam with fake engines and
/// record which method each one was called through.
///
/// Where the layers sit, so nothing here is read as more than it is: the SERVICE's cut is
/// conformance — an engine that does not declare a context protocol is never handed one. The
/// engine-era *mode* gate is upstream, in the capture path (`wantsFieldText`), and is tested in
/// the hosted `FieldContextGateTests`. This file does not re-test that gate; it tests what happens
/// once a context has been resolved.
@MainActor
final class FieldContextConformanceCutTests: CoreTestCase {

    /// What a fake engine saw. A reference type so the engine and the test share it.
    private final class Recorder {
        var proseContext: String?
        var terms: [String]?
        var plainCalls = 0
        var contextCalls = 0
    }

    private class StubEngine: TranscriptionEngine {
        let recorder = Recorder()
        var engineName: String { "Stub" }
        var isModelLoaded: Bool { true }

        func initialize() async throws {}

        func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String {
            recorder.plainCalls += 1
            return "plain"
        }

        func cancelTranscription() {}
        func getSupportedLanguages() -> [String] { ["en"] }
    }

    private final class ProseStub: StubEngine, ProseContextEngine {
        func transcribeAudio(url: URL, settings: TranscriptionSettings,
                             proseContext: String) async throws -> String {
            recorder.contextCalls += 1
            recorder.proseContext = proseContext
            return "prose"
        }
    }

    private final class TermStub: StubEngine, TermContextEngine {
        func transcribeAudio(url: URL, settings: TranscriptionSettings,
                             terms: [String]) async throws -> String {
            recorder.contextCalls += 1
            recorder.terms = terms
            return "terms"
        }
    }

    // MARK: - Helpers

    private func settings(fieldContext: Bool) -> TranscriptionSettings {
        var settings = Fixtures.pinnedSettings()
        settings.useSurroundingTextAsContext = fieldContext
        return settings
    }

    private func service(_ engine: TranscriptionEngine) -> TranscriptionService {
        TranscriptionService(engineBuilder: { _ in engine })
    }

    // MARK: - The engine that declares a context protocol gets it

    /// Whisper's path, end to end through the service. Mutation: make `resolveFieldContext`
    /// return nil, or drop the prose branch, and the context is never delivered.
    func testAProseEngineIsHandedTheField() async throws {
        CoreTestEnvironment.preferences.selectedEngine = "whisper"
        let engine = ProseStub()

        _ = try await service(engine).transcribeAudio(
            url: Fixtures.jfkWav, settings: settings(fieldContext: true),
            capturedFieldText: "the Nyiragongo trail")

        XCTAssertEqual(engine.recorder.proseContext, "the Nyiragongo trail")
        XCTAssertEqual(engine.recorder.plainCalls, 0, "the context-bearing method was bypassed")
    }

    /// Parakeet's path. This is the test that reddens if `resolveFieldContext` returns `.prose`
    /// for every engine: a `.prose` context does not match a term engine, so the terms would be
    /// dropped and the plain method used.
    func testATermEngineIsHandedTheFieldsTerms() async throws {
        CoreTestEnvironment.preferences.selectedEngine = "fluidaudio"
        let engine = TermStub()

        _ = try await service(engine).transcribeAudio(
            url: Fixtures.jfkWav, settings: settings(fieldContext: true),
            capturedFieldText: "Cherith met Nyiragongo")

        XCTAssertEqual(engine.recorder.terms, ["Cherith", "Nyiragongo"])
        XCTAssertEqual(engine.recorder.plainCalls, 0)
    }

    // MARK: - The engine that does not declare one never sees it

    /// The mistaken-capability case: the selection says Whisper, and the engine that actually
    /// runs declares no context protocol. The cut must drop the text rather than pass it — the
    /// cast is what makes the flip harmless.
    func testAnEngineWithoutTheProtocolIsCalledPlainly() async throws {
        CoreTestEnvironment.preferences.selectedEngine = "whisper"
        let engine = StubEngine()

        _ = try await service(engine).transcribeAudio(
            url: Fixtures.jfkWav, settings: settings(fieldContext: true),
            capturedFieldText: "a private sentence")

        XCTAssertEqual(engine.recorder.plainCalls, 1)
        XCTAssertEqual(engine.recorder.contextCalls, 0)
        XCTAssertNil(engine.recorder.proseContext)
    }

    /// The remote engine's shape in production: it declares neither protocol, so whatever the
    /// selection says, the only method it can be called through carries no field text.
    func testTheRemoteShapeEngineIsNeverHandedAContext() async throws {
        CoreTestEnvironment.preferences.selectedEngine = "remote"
        let engine = StubEngine()

        _ = try await service(engine).transcribeAudio(
            url: Fixtures.jfkWav, settings: settings(fieldContext: true),
            capturedFieldText: "a private sentence")

        XCTAssertEqual(engine.recorder.plainCalls, 1)
        XCTAssertEqual(engine.recorder.contextCalls, 0)
    }

    // MARK: - Nothing to resolve

    /// The switch off: a conforming engine still gets nothing. Mutation: drop the `enabled`
    /// argument to `TranscriptionPrompt.surroundingText` and the prose is delivered anyway.
    func testTheSwitchOffDeliversNothingEvenToAConformingEngine() async throws {
        CoreTestEnvironment.preferences.selectedEngine = "whisper"
        let engine = ProseStub()

        _ = try await service(engine).transcribeAudio(
            url: Fixtures.jfkWav, settings: settings(fieldContext: false),
            capturedFieldText: "a private sentence")

        XCTAssertNil(engine.recorder.proseContext)
        XCTAssertEqual(engine.recorder.plainCalls, 1)
    }

    /// No capture, which is what the remote engine's gate produces upstream: the service has
    /// nothing to hand over even to an engine that could take it.
    func testNoCapturedTextDeliversNothing() async throws {
        CoreTestEnvironment.preferences.selectedEngine = "whisper"
        let engine = ProseStub()

        _ = try await service(engine).transcribeAudio(
            url: Fixtures.jfkWav, settings: settings(fieldContext: true),
            capturedFieldText: nil)

        XCTAssertNil(engine.recorder.proseContext)
        XCTAssertEqual(engine.recorder.plainCalls, 1)
    }
}
