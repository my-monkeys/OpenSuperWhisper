import XCTest
import os
@testable import OpenSuperWhisperCore

final class TranscriptionServiceStaleLoadTests: CoreTestCase {

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
    func testALoadOvertakenByAModelSwitchServesOnlyTheCallerWaitingOnIt() async throws {
        let preferences = CoreTestEnvironment.preferences
        let firstModel = "/models/ggml-first.bin"
        let secondModel = "/models/ggml-second.bin"
        preferences.selectedEngine = "whisper"
        preferences.selectedWhisperModelPath = firstModel
        let firstLoadStarted = AsyncSemaphore(0)
        let finishFirstLoad = AsyncSemaphore(0)
        let builtModels = OSAllocatedUnfairLock(initialState: [String]())
        let service = TranscriptionService(engineBuilder: { _ in
            let modelPath = preferences.selectedWhisperModelPath ?? ""
            builtModels.withLock { $0.append(modelPath) }
            if modelPath == firstModel {
                await firstLoadStarted.signal()
                await finishFirstLoad.wait()
            }
            return StubEngine(transcript: modelPath)
        })

        let waitingTranscription = Task {
            try await service.transcribeAudio(url: Fixtures.jfkWav, settings: Fixtures.pinnedSettings())
        }
        await firstLoadStarted.wait()
        service.reloadModel(with: secondModel)
        await finishFirstLoad.signal()

        let waitingTranscript = try await waitingTranscription.value
        XCTAssertEqual(waitingTranscript, firstModel)
        XCTAssertEqual(service.lastUsedModel?.identifier, firstModel)

        let nextTranscript = try await service.transcribeAudio(url: Fixtures.jfkWav,
                                                               settings: Fixtures.pinnedSettings())
        XCTAssertEqual(nextTranscript, secondModel)
        XCTAssertEqual(service.lastUsedModel?.identifier, secondModel)
        XCTAssertEqual(builtModels.withLock { $0 }, [firstModel, secondModel])
        XCTAssertFalse(service.isLoading)
    }
}
