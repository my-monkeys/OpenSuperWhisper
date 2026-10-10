import XCTest
@testable import OpenSuperWhisperCore

/// llama under `.cpuOnly`: no layer offloaded. Reads the model only from `OSW_TEST_GGUF`
/// (`TEST_RUNNER_OSW_TEST_GGUF` through xcodebuild), opened read-only, and skips without it, so CI
/// never runs these.
final class CoreLlamaComputePolicyTests: CoreTestCase {

    private var modelLink: URL?

    override func tearDown() {
        // removeItem on a symlink removes the link, never the model it points at.
        if let modelLink { try? FileManager.default.removeItem(at: modelLink) }
        modelLink = nil
        super.tearDown()
    }

    func testCPUOnlyContextLoadsAndGenerates() throws {
        let model = try requireModel()
        let context = try XCTUnwrap(LlamaContext(modelPath: model.path, gpuLayers: 0))
        let output = context.generate(system: "Reply with one word.", user: "Say hello.", maxTokens: 16)
        XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// The backend finds the selected model under the storage root and loads it with no GPU layer:
    /// the first run of `.cpuOnly` on the llama side.
    func testBackendUnderCPUOnlyAnswersFromTheSelectedModel() async throws {
        let model = try requireModel()
        let link = LLMModelManager.shared.localURL(for: CoreTestEnvironment.preferences.builtInModelFileName)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: model)
        modelLink = link

        let backend = BuiltInLlamaBackend(computePolicy: .cpuOnly)
        XCTAssertTrue(backend.isReady)
        let output = try await backend.generate(system: "Reply with one word.", user: "Say hello.")
        XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func requireModel() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["OSW_TEST_GGUF"], !path.isEmpty else {
            throw XCTSkip("OSW_TEST_GGUF is not set")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw XCTSkip("OSW_TEST_GGUF does not name a readable file: \(path)")
        }
        return URL(fileURLWithPath: path)
    }
}
