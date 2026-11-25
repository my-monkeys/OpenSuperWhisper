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
/// Where the layers sit: the service refuses context twice over — once by the selected engine's
/// mode (`EngineCapabilities.supportsFieldContext`), once by the engine's declared conformance.
/// The mode check is the layer that holds when the capture gate did not run (a stub, a fallback
/// path, a future engine); the conformance check is the layer that holds when a capability is
/// mis-declared. The capture gate itself is tested in the hosted `FieldContextGateTests`; this
/// file tests the dispatch.
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

    private func settings(fieldContext: Bool, language: String = "en") -> TranscriptionSettings {
        var settings = Fixtures.pinnedSettings()
        settings.useSurroundingTextAsContext = fieldContext
        settings.selectedLanguage = language
        return settings
    }

    private func service(_ engine: TranscriptionEngine) -> TranscriptionService {
        TranscriptionService(engineBuilder: { _ in engine })
    }

    /// Installs a configuration whose spelling provider is `spelling`, for the body only. The
    /// test environment's configuration is restored even when an assertion fails, so a later
    /// class cannot inherit a provider from this one.
    private func withSpelling(
        _ spelling: @escaping @MainActor @Sendable (String?) -> DictionaryCandidates.Spelling,
        _ body: () async throws -> Void
    ) async rethrows {
        var configuration = CoreTestEnvironment.configuration
        configuration.fieldTermSpelling = spelling
        CoreConfiguration.replaceForTesting(configuration)
        defer { CoreConfiguration.replaceForTesting(CoreTestEnvironment.configuration) }
        try await body()
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

    /// The mode, not only the conformance — the case where both layers disagree.
    ///
    /// A conforming engine selected as `remote`, handed the captured text directly: the capture
    /// gate would have refused to read the field for this engine, but the text is here anyway, so
    /// the dispatch has to refuse it too. Mutation: drop the mode guard from
    /// `resolveFieldContext` and the prose is delivered — this reddens and nothing else does.
    func testAConformingEngineSelectedAsRemoteReceivesNothing() async throws {
        CoreTestEnvironment.preferences.selectedEngine = "remote"
        let engine = ProseStub()

        _ = try await service(engine).transcribeAudio(
            url: Fixtures.jfkWav, settings: settings(fieldContext: true),
            capturedFieldText: "a private sentence")

        XCTAssertNil(engine.recorder.proseContext, "the remote selection did not stop the context")
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

    // MARK: - The spelling provider is the one the service resolves with

    /// The provider's answers decide which words reach the term engine. Mutation: replace the
    /// `CoreAccess.fieldTermSpelling` call in `resolveFieldContext` with a fixed knows-nothing
    /// dictionary and "Cherith" is delivered — this row reddens. A test that only reads the
    /// provider back through `CoreAccess` stays green under that change.
    func testTheSpellingProviderDecidesWhichWordsAreTerms() async throws {
        try await withSpelling({ _ in
            DictionaryCandidates.Spelling(knows: { $0.lowercased() == "cherith" },
                                          correctsTypo: { _ in false })
        }) {
            CoreTestEnvironment.preferences.selectedEngine = "fluidaudio"
            let engine = TermStub()

            _ = try await service(engine).transcribeAudio(
                url: Fixtures.jfkWav, settings: settings(fieldContext: true),
                capturedFieldText: "Cherith met Nyiragongo")

            XCTAssertEqual(engine.recorder.terms, ["Nyiragongo"],
                           "the provider's answer did not reach the reducer")
            XCTAssertEqual(engine.recorder.plainCalls, 0)
        }
    }

    /// The clip's language reaches the provider: the same text is judged against a German
    /// dictionary and an English one. Mutation: pass nil (or a guessed language) to
    /// `CoreAccess.fieldTermSpelling` and the German row receives "Cherith" — this reddens.
    func testTheClipsLanguageReachesTheSpellingProvider() async throws {
        try await withSpelling({ language in
            language == "de"
                ? DictionaryCandidates.Spelling(knows: { $0.lowercased() == "cherith" },
                                                correctsTypo: { _ in false })
                : DictionaryCandidates.Spelling(knows: { _ in false }, correctsTypo: { _ in false })
        }) {
            CoreTestEnvironment.preferences.selectedEngine = "fluidaudio"

            let german = TermStub()
            _ = try await service(german).transcribeAudio(
                url: Fixtures.jfkWav, settings: settings(fieldContext: true, language: "de"),
                capturedFieldText: "Cherith met Nyiragongo")
            XCTAssertEqual(german.recorder.terms, ["Nyiragongo"],
                           "the clip's language did not cross: the German dictionary was not used")

            let english = TermStub()
            _ = try await service(english).transcribeAudio(
                url: Fixtures.jfkWav, settings: settings(fieldContext: true, language: "en"),
                capturedFieldText: "Cherith met Nyiragongo")
            XCTAssertEqual(english.recorder.terms, ["Cherith", "Nyiragongo"])
        }
    }

    /// The clip's language also decides the capital rule, through the run a capitalised known
    /// word witnesses. Mutation: hardcode `capitalMarksNames` true and the German row delivers
    /// "Thier"; hardcode it false and the English row delivers nothing — one of them reddens.
    func testTheClipsLanguageDecidesTheCapitalRule() async throws {
        try await withSpelling({ _ in
            DictionaryCandidates.Spelling(knows: { $0.lowercased() == "parakeet" },
                                          correctsTypo: { $0.lowercased() == "thier" })
        }) {
            CoreTestEnvironment.preferences.selectedEngine = "fluidaudio"

            let english = TermStub()
            _ = try await service(english).transcribeAudio(
                url: Fixtures.jfkWav, settings: settings(fieldContext: true, language: "en"),
                capturedFieldText: "Thier Parakeet")
            XCTAssertEqual(english.recorder.terms, ["Thier"])

            let german = TermStub()
            _ = try await service(german).transcribeAudio(
                url: Fixtures.jfkWav, settings: settings(fieldContext: true, language: "de"),
                capturedFieldText: "Thier Parakeet")
            XCTAssertNil(german.recorder.terms,
                         "the German capital rule did not refuse the sentence-start typo")
            XCTAssertEqual(german.recorder.plainCalls, 1)
        }
    }

    // MARK: - The resolution taken before the engine gate

    /// A resolution answers only for the engine it was decided on: a non-nil value survives a
    /// reload by conformance, and a nil survives only on the same instance — "nothing for
    /// Parakeet" is not "nothing for Whisper", which would be handed the prose.
    /// Mutation: return true unconditionally and the cross-engine rows redden; return false
    /// unconditionally and the same-instance and non-nil rows redden.
    func testAResolutionIsReusedOnlyOnTheEngineItAnswersFor() {
        let prose = ProseStub()
        let otherProse = ProseStub()
        let terms = TermStub()
        let plain = StubEngine()

        XCTAssertFalse(FieldContextResolution.notResolved.reusable(on: prose))
        XCTAssertNil(FieldContextResolution.notResolved.value)

        let proseValue = FieldContextResolution.resolved(.prose("text"), on: plain)
        XCTAssertTrue(proseValue.reusable(on: prose), "a non-nil value survives by conformance")
        XCTAssertTrue(proseValue.reusable(on: otherProse))
        XCTAssertFalse(proseValue.reusable(on: terms))
        XCTAssertFalse(proseValue.reusable(on: plain))

        let termValue = FieldContextResolution.resolved(.terms(["Cherith"]), on: prose)
        XCTAssertTrue(termValue.reusable(on: terms))
        XCTAssertFalse(termValue.reusable(on: prose))

        let emptyOnProse = FieldContextResolution.resolved(nil, on: prose)
        XCTAssertTrue(emptyOnProse.reusable(on: prose), "the same engine may reuse its own nil")
        XCTAssertFalse(emptyOnProse.reusable(on: otherProse),
                       "a nil decided for one engine is not a nil for another")
        XCTAssertNil(emptyOnProse.value)
    }

    /// The pre-gate path, through the service: the second transcription of an already-loaded
    /// engine resolves before the engine gate and reuses that resolution, so two clips ask the
    /// provider twice, not three times. Mutation: make `reusable(on:)` always false and the
    /// second count is three — red. The first call cannot take the path (nothing is loaded yet).
    func testThePreGateResolutionIsReusedAcrossTwoTranscriptions() async throws {
        let calls = ProviderCalls()
        try await withSpelling({ _ in
            calls.record()
            return DictionaryCandidates.Spelling(knows: { $0.lowercased() == "cherith" },
                                                 correctsTypo: { _ in false })
        }) {
            CoreTestEnvironment.preferences.selectedEngine = "fluidaudio"
            let engine = TermStub()
            let service = self.service(engine)

            _ = try await service.transcribeAudio(
                url: Fixtures.jfkWav, settings: settings(fieldContext: true),
                capturedFieldText: "Cherith met Nyiragongo")
            XCTAssertEqual(calls.total, 1, "the first clip resolves once, after the engine loads")

            _ = try await service.transcribeAudio(
                url: Fixtures.jfkWav, settings: settings(fieldContext: true),
                capturedFieldText: "Cherith met Nyiragongo")
            XCTAssertEqual(calls.total, 2,
                           "the second clip resolved before the gate and was not resolved again")
            XCTAssertEqual(engine.recorder.terms, ["Nyiragongo"])
        }
    }
}

/// Counts provider asks from the `@Sendable` closure. A reference type with a lock, so the
/// closure can capture it without a shared-mutable-state warning.
private final class ProviderCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
