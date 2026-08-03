import Foundation
import XCTest
import WhisperCore  // PLAIN import — deliberately NOT @testable (S-2, PR #57 review
// cycle 1). Every other test file in this target consumes WhisperCore via @testable,
// which sees internal symbols and therefore cannot catch a missing `public` on the
// iOS-facing API Cycle 2 will build against. If a symbol exercised below loses its
// access level, THIS file fails to compile — the blind spot fails loudly.

/// A minimal conformance proving the protocol's required members are all public.
/// An internal-only witness would still satisfy @testable consumers; only a plain-import
/// conformance pins the public contract.
private final class DummyEngine: TranscriptionEngine {
    var isModelLoaded = false
    let engineName = "dummy"
    func initialize() async throws {}
    func transcribeAudio(url: URL, settings: Settings) async throws -> String { "" }
    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { [] }
}

final class PublicConsumptionTests: XCTestCase {

    // S-12: pin the byte-identical layout claim (WhisperCore/StorageLocations.swift:9)
    // ahead of the Cycle-4 App Group flip — all four URLs, parent + leaf.
    func testStorageLocationsURLsMatchPreCycle4Layout() {
        let appSupport = StorageLocations.appSupportDirectory
        XCTAssertEqual(appSupport.lastPathComponent, Bundle.main.bundleIdentifier,
                       "appSupportDirectory must remain <Application Support>/<bundle-id>")
        XCTAssertEqual(StorageLocations.recordingsDirectory.deletingLastPathComponent(), appSupport)
        XCTAssertEqual(StorageLocations.recordingsDirectory.lastPathComponent, "recordings")
        XCTAssertEqual(StorageLocations.recordingsDatabaseURL.deletingLastPathComponent(), appSupport)
        XCTAssertEqual(StorageLocations.recordingsDatabaseURL.lastPathComponent, "recordings.sqlite")
        XCTAssertEqual(StorageLocations.whisperModelsDirectory.deletingLastPathComponent(), appSupport)
        XCTAssertEqual(StorageLocations.whisperModelsDirectory.lastPathComponent, "whisper-models")
    }

    // S-2: the translate-toggle gating (#124) is iOS-facing decision logic.
    func testEngineCapabilitiesTranslationGatingViaPublicAPI() {
        XCTAssertTrue(EngineCapabilities.supportsTranslation(engine: "whisper"))
        XCTAssertTrue(EngineCapabilities.supportsTranslation(engine: "remote"))
        XCTAssertFalse(EngineCapabilities.supportsTranslation(engine: "fluidaudio"))
        XCTAssertFalse(EngineCapabilities.supportsTranslation(engine: "sensevoice"))
    }

    // S-2: catalog options must stay well-formed through the public surface, whatever
    // the host has downloaded (content is host-dependent; shape is not).
    func testModelCatalogPublicSurfaceReturnsWellFormedOptions() {
        for option in ModelCatalog.whisperModels() {
            XCTAssertEqual(option.engine, "whisper")
            XCTAssertFalse(option.identifier.isEmpty)
            XCTAssertFalse(option.displayName.isEmpty)
        }
        for option in ModelCatalog.senseVoiceModels() {
            XCTAssertEqual(option.engine, "sensevoice")
        }
        _ = ModelCatalog.parakeetModels()  // consumption proof; content is host-dependent
    }

    // S-2: the engine protocol (and the Settings type its signature exposes) must be
    // publicly conformable/consumable for Cycle 2 iOS engine use.
    func testTranscriptionEngineProtocolIsPubliclyConsumable() {
        let engine: any TranscriptionEngine = DummyEngine()
        XCTAssertEqual(engine.engineName, "dummy")
        XCTAssertFalse(engine.isModelLoaded)
        _ = Settings()  // public init; reads shared prefs, no side effects
    }
}
