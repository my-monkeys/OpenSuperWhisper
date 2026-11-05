import XCTest
@testable import OpenSuperWhisperCore

final class RemoteServiceTests: CoreTestCase {

    func testBaseURLsAreTheDocumentedOnes() {
        XCTAssertEqual(RemoteService.openRouter.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(RemoteService.openAI.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(RemoteService.gemini.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai/")
        XCTAssertEqual(RemoteService.groq.baseURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(RemoteService.mistral.baseURL, "https://api.mistral.ai/v1")
    }

    func testEveryServiceResolvesItsChatAndModelsEndpoint() {
        let chat = ["https://openrouter.ai/api/v1/chat/completions",
                    "https://api.openai.com/v1/chat/completions",
                    "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                    "https://api.groq.com/openai/v1/chat/completions",
                    "https://api.mistral.ai/v1/chat/completions"]
        XCTAssertEqual(RemoteService.allCases.map {
            OpenAICompatibleURL.endpoint(base: $0.baseURL, resource: "chat/completions")?.absoluteString
        }, chat)
        XCTAssertEqual(OpenAICompatibleURL.endpoint(base: RemoteService.gemini.baseURL, resource: "models")?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/openai/models")
    }

    func testDetectsEachServiceFromItsURL() {
        for service in RemoteService.allCases {
            XCTAssertEqual(RemoteService.detect(url: service.baseURL), service)
        }
        XCTAssertEqual(RemoteService.detect(url: "HTTPS://API.GROQ.COM/openai/v1"), .groq)
        XCTAssertNil(RemoteService.detect(url: "http://litellm.docker.lan:4000/v1"))
        XCTAssertNil(RemoteService.detect(url: ""))
    }

    func testOnlyServicesWithATranscriptionEndpointAreOfferedForTranscription() {
        XCTAssertEqual(RemoteService.transcriptionServices, [.openAI, .groq, .mistral])
        XCTAssertTrue(RemoteService.openRouter.transcriptionModels.isEmpty)
        XCTAssertTrue(RemoteService.gemini.transcriptionModels.isEmpty)
    }

    func testGroqKeepsItsCuratedModels() {
        let ids = RemoteService.groq.transcriptionModels.map(\.id)
        XCTAssertEqual(ids, ["whisper-large-v3-turbo", "whisper-large-v3"])
        XCTAssertEqual(RemoteService.groq.defaultTranscriptionModel, "whisper-large-v3-turbo")
        XCTAssertEqual(RemoteService.groq.translatingModel, "whisper-large-v3")
        XCTAssertNotEqual(RemoteService.groq.defaultTranscriptionModel, RemoteService.groq.translatingModel)
    }

    // MARK: Key prefix

    func testKeyPrefixWarning() {
        XCTAssertFalse(RemoteService.groq.keyLooksForeign("gsk_abc"))
        XCTAssertTrue(RemoteService.groq.keyLooksForeign("sk-or-v1-abc"))
        XCTAssertFalse(RemoteService.openRouter.keyLooksForeign("sk-or-v1-abc"))
        XCTAssertTrue(RemoteService.openRouter.keyLooksForeign("gsk_abc"))
        XCTAssertFalse(RemoteService.openAI.keyLooksForeign("sk-proj-abc"))
        XCTAssertTrue(RemoteService.openAI.keyLooksForeign("sk-or-v1-abc"), "an OpenRouter key is not an OpenAI key")
        XCTAssertFalse(RemoteService.gemini.keyLooksForeign("AIzaSyabc"))
        XCTAssertTrue(RemoteService.gemini.keyLooksForeign("gsk_abc"))
    }

    func testEmptyKeysAndMistralNeverWarn() {
        for service in RemoteService.allCases { XCTAssertFalse(service.keyLooksForeign("  ")) }
        XCTAssertFalse(RemoteService.mistral.keyLooksForeign("anything"))
        XCTAssertNil(RemoteService.mistral.keyPrefixHint)
    }

    // MARK: Reasoning

    private func fields(_ service: RemoteService?, _ model: String) -> NSDictionary {
        RemoteService.reasoningFields(service: service, model: model) as NSDictionary
    }

    func testOpenRouterGetsTheUnifiedReasoningObjectAndLatencySort() {
        XCTAssertEqual(fields(.openRouter, "google/gemini-2.5-flash-lite"),
                       ["reasoning": ["effort": "none"], "provider": ["sort": "latency"]])
    }

    func testOpenAISendsReasoningEffortOnlyToModelsThatReason() {
        XCTAssertEqual(fields(.openAI, "gpt-5.4-nano"), ["reasoning_effort": "none"])
        XCTAssertEqual(fields(.openAI, "gpt-6-luna"), ["reasoning_effort": "none"])
        XCTAssertEqual(fields(.openAI, "gpt-4.1-mini"), [:], "a non-reasoning model refuses the field")
    }

    func testGeminiPicksTheValueItsModelFamilyAccepts() {
        XCTAssertEqual(fields(.gemini, "gemini-2.5-flash-lite"), ["reasoning_effort": "none"])
        XCTAssertEqual(fields(.gemini, "gemini-3.5-flash-lite"), ["reasoning_effort": "minimal"])
        XCTAssertEqual(fields(.gemini, "gemini-2.5-pro"), [:], "Pro cannot turn thinking off")
    }

    func testGroqAndMistralOnlyForTheModelsThatTakeIt() {
        XCTAssertEqual(fields(.groq, "qwen/qwen3.8-27b"), ["reasoning_effort": "none"])
        XCTAssertEqual(fields(.groq, "openai/gpt-oss-20b"), ["reasoning_effort": "low"], "its minimum")
        XCTAssertEqual(fields(.groq, "llama-3.1-8b-instant"), [:])
        XCTAssertEqual(fields(.mistral, "mistral-small-2603"), ["reasoning_effort": "none"])
        XCTAssertEqual(fields(.mistral, "mistral-large-4-0"), [:])
    }

    func testCustomServerGetsOpenAIsFieldOnlyWhenAsked() {
        XCTAssertEqual(fields(nil, "whatever"), ["reasoning_effort": "none"])
        XCTAssertFalse(RemoteService.disablesReasoning(stored: nil, service: nil))
        XCTAssertTrue(RemoteService.disablesReasoning(stored: true, service: nil))
        XCTAssertTrue(RemoteService.disablesReasoning(stored: nil, service: .openRouter))
        XCTAssertFalse(RemoteService.disablesReasoning(stored: false, service: .openRouter))
    }

    func testNothingIsAddedWhenTheSwitchIsOff() {
        let off = RemoteBackend.reasoningFields(endpoint: RemoteService.openRouter.baseURL, model: "m", disabled: false)
        XCTAssertTrue(off.isEmpty)
        let on = RemoteBackend.reasoningFields(endpoint: RemoteService.openRouter.baseURL, model: "m", disabled: true)
        XCTAssertNotNil(on["reasoning"])
    }
}
