import XCTest
@testable import OpenSuperWhisperCore

/// The instructions box is live only where an engine reads it (#229 upstream): elsewhere it is
/// disabled with the reason, rather than a box that takes text and changes nothing.
final class PromptCapabilityTests: XCTestCase {
    func testOnlyWhisperAndTheRemoteEngineReadThePrompt() {
        XCTAssertTrue(EngineCapabilities.readsPrompt(engine: "whisper"))
        XCTAssertTrue(EngineCapabilities.readsPrompt(engine: "remote"))
        for engine in ["fluidaudio", "sensevoice", "apple"] {
            XCTAssertFalse(EngineCapabilities.readsPrompt(engine: engine), engine)
        }
    }
}
