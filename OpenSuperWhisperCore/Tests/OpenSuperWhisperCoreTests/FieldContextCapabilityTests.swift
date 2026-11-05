import XCTest
@testable import OpenSuperWhisperCore

/// Which engines may be told what is already written in the field (#89), and the list they are
/// enumerated from.
///
/// The mode is asserted through an exhaustive `switch` rather than an equality, so a fifth case
/// is a compile error here as well as in the app. `FieldContextMode` does not declare `Equatable`
/// and I could not compile this to check whether the simple-enum synthesis applies, so the switch
/// avoids depending on an answer I cannot verify on this machine.
final class FieldContextCapabilityTests: CoreTestCase {

    /// `allEngineIds` is the one list, so it has to be a list: five ids, no duplicates, and every
    /// one of them answered.
    func testEveryEngineIdIsListedOnceAndHasAMode() {
        XCTAssertEqual(EngineCapabilities.allEngineIds.count, 5)
        XCTAssertEqual(Set(EngineCapabilities.allEngineIds).count, 5,
                       "a duplicate id is not a list")

        for id in EngineCapabilities.allEngineIds {
            switch EngineCapabilities.fieldContextMode(for: id) {
            case .prose:
                XCTAssertEqual(id, "whisper")
            case .terms:
                XCTAssertEqual(id, "fluidaudio")
            case .remoteExcluded:
                XCTAssertEqual(id, "remote")
            case .none:
                XCTAssertTrue(["apple", "sensevoice"].contains(id), id)
            }
        }
    }

    /// The list is a source of truth only if it covers every engine kind, and the kinds are what
    /// the service actually dispatches on.
    ///
    /// Both availability gates are forced open on purpose. On an Intel build `sensevoice` folds
    /// onto `.whisper`, and without the macOS 26 speech stack `apple` does too, so the default
    /// arguments would make this pin fail for a reason that is not a defect.
    func testTheListCoversEveryEngineKind() {
        let kinds = EngineCapabilities.allEngineIds.map {
            TranscriptionService.engineKind(forSelectedEngine: $0,
                                            senseVoiceAvailable: true,
                                            appleSpeechAvailable: true)
        }

        XCTAssertEqual(kinds.count, TranscriptionService.EngineKind.allCases.count)
        // Exactly one id per case, compared as cases rather than as descriptions: a count plus a
        // membership check would still admit a duplicate, and `String(describing:)` would keep
        // passing if a case were renamed to collide. This needs only `Equatable`.
        for kind in TranscriptionService.EngineKind.allCases {
            XCTAssertEqual(kinds.filter { $0 == kind }.count, 1,
                           "engine kinds are not one-to-one; \(kind) appears a different number of times")
        }
    }

    /// The gate the app actually calls, checked against the mode it is derived from, per engine.
    func testSupportsFieldContextAgreesWithTheMode() {
        for id in EngineCapabilities.allEngineIds {
            XCTAssertEqual(EngineCapabilities.supportsFieldContext(engine: id),
                           EngineCapabilities.fieldContextMode(for: id).suppliesFieldContext,
                           id)
        }
    }

    /// The four answers in full, because "capable" is not the only thing that matters: Whisper
    /// takes prose, Parakeet takes terms, and the other three take nothing for two different
    /// reasons — one cannot, one will not.
    func testOnlyWhisperAndParakeetAreCapable() {
        XCTAssertTrue(EngineCapabilities.supportsFieldContext(engine: "whisper"))
        XCTAssertTrue(EngineCapabilities.supportsFieldContext(engine: "fluidaudio"))
        XCTAssertFalse(EngineCapabilities.supportsFieldContext(engine: "remote"))
        XCTAssertFalse(EngineCapabilities.supportsFieldContext(engine: "apple"))
        XCTAssertFalse(EngineCapabilities.supportsFieldContext(engine: "sensevoice"))
    }

    /// The derivation a shorthand gets wrong. `.remoteExcluded` is not `.none`, so `mode != .none`
    /// would mark the one engine that must never see the field as capable, enable its Settings
    /// toggle and open its capture gate. The enum comment says so; this pins it.
    func testRemoteExcludedIsNotCapable() {
        XCTAssertFalse(FieldContextMode.remoteExcluded.suppliesFieldContext)
        XCTAssertTrue(FieldContextMode.prose.suppliesFieldContext)
        XCTAssertTrue(FieldContextMode.terms.suppliesFieldContext)
        XCTAssertFalse(FieldContextMode.none.suppliesFieldContext)
    }

    /// An id this build has never heard of is not capable. Guessing `.prose` would read a
    /// document for an engine that may not even be local.
    func testAnUnknownEngineIsNotCapable() {
        XCTAssertFalse(EngineCapabilities.supportsFieldContext(engine: "groq"))
        XCTAssertFalse(EngineCapabilities.supportsFieldContext(engine: ""))
    }

    /// The table is a claim about engines, so it is checked against the engines. A mode entry with
    /// no conforming engine behind it is #126 in reverse — a switch that turns a feature on with
    /// nothing to consume it — and the table alone cannot see that.
    func testTheCapableEnginesConformToTheirProtocol() {
        XCTAssertNotNil(WhisperEngine.self as? ProseContextEngine.Type)
        XCTAssertNotNil(FluidAudioEngine.self as? TermContextEngine.Type)

        // And not to the wrong one: prose handed to a terms engine would run a spelling pass for
        // nothing, and a term list handed to Whisper would replace its prompt with vocabulary.
        XCTAssertNil(WhisperEngine.self as? TermContextEngine.Type)
        XCTAssertNil(FluidAudioEngine.self as? ProseContextEngine.Type)
    }
}
