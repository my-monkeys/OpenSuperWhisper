import XCTest
@testable import OpenSuperWhisper

final class CleanupBackendOptionsTests: XCTestCase {
    private func setup(apple: Bool = false, builtIn: String? = nil, ollama: String = "",
                       remote: String = "") -> CleanupBackendOptions.Setup {
        .init(appleIntelligenceAvailable: apple, builtInModelLabel: builtIn,
              ollamaEndpoint: ollama, ollamaModel: "llama3.2",
              remoteEndpoint: remote, remoteModel: "google/gemini-2.5-flash-lite")
    }

    func testOnlyWhatThisMacIsSetUpForIsOffered() {
        XCTAssertEqual(CleanupBackendOptions.available(setup()).map(\.tag), [])
        XCTAssertEqual(CleanupBackendOptions.available(setup(apple: true, builtIn: "Qwen", ollama: " ", remote: "https://x"))
            .map(\.tag), ["apple", "builtin", "remote"])
    }

    func testOnlyOllamaAndRemoteHaveAModelToReplace() {
        let options = CleanupBackendOptions.available(setup(apple: true, builtIn: "Qwen", ollama: "http://l", remote: "https://x"))
        XCTAssertEqual(options.map(\.editsModel), [false, false, true, true])
        XCTAssertEqual(options.last?.configuredModel, "google/gemini-2.5-flash-lite")
    }

    func testTheDefaultIsTheBackendOfTheFirstCleanupWhenThisMacStillHasIt() {
        let options = CleanupBackendOptions.available(setup(apple: true, ollama: "http://l", remote: "https://x"))
        XCTAssertEqual(CleanupBackendOptions.defaultTag(firstModel: "google/gemini-2.5-flash-lite", current: "apple", in: options), "remote")
        XCTAssertEqual(CleanupBackendOptions.defaultTag(firstModel: "gone-model", current: "ollama", in: options), "ollama")
        XCTAssertEqual(CleanupBackendOptions.defaultTag(firstModel: nil, current: "builtin", in: options), "apple",
                       "the current backend is not set up: the first one there is")
        XCTAssertNil(CleanupBackendOptions.defaultTag(firstModel: nil, current: "apple", in: []))
    }
}
