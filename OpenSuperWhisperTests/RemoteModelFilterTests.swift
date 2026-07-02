import XCTest
@testable import OpenSuperWhisper

/// `/v1/models` has no capability field, so the Remote settings panel guesses which
/// models are speech-to-text from their ids (RemoteModelFilter) and hides the rest
/// behind "show all". These pin the guess for the model families real providers list.
final class RemoteModelFilterTests: XCTestCase {

    func testWhisperFamiliesAreSTT() {
        XCTAssertTrue(RemoteModelFilter.isLikelySpeechToText("whisper-1"))
        XCTAssertTrue(RemoteModelFilter.isLikelySpeechToText("whisper-large-v3-turbo"))
        XCTAssertTrue(RemoteModelFilter.isLikelySpeechToText("distil-whisper-large-v3-en"))
        XCTAssertTrue(RemoteModelFilter.isLikelySpeechToText("Systran/faster-whisper-medium"))
    }

    func testOtherSTTFamiliesAreSTT() {
        XCTAssertTrue(RemoteModelFilter.isLikelySpeechToText("gpt-4o-transcribe"))
        XCTAssertTrue(RemoteModelFilter.isLikelySpeechToText("gpt-4o-mini-transcribe"))
        XCTAssertTrue(RemoteModelFilter.isLikelySpeechToText("voxtral-mini-latest"))
        XCTAssertTrue(RemoteModelFilter.isLikelySpeechToText("nvidia/canary-1b"))
        XCTAssertTrue(RemoteModelFilter.isLikelySpeechToText("scribe_v1"))
        XCTAssertTrue(RemoteModelFilter.isLikelySpeechToText("my-custom-asr"))
    }

    func testChatEmbeddingAndImageModelsAreNot() {
        XCTAssertFalse(RemoteModelFilter.isLikelySpeechToText("llama-3.3-70b-versatile"))
        XCTAssertFalse(RemoteModelFilter.isLikelySpeechToText("gemma2-9b-it"))
        XCTAssertFalse(RemoteModelFilter.isLikelySpeechToText("gpt-4o"))
        XCTAssertFalse(RemoteModelFilter.isLikelySpeechToText("text-embedding-3-small"))
        XCTAssertFalse(RemoteModelFilter.isLikelySpeechToText("dall-e-3"))
        XCTAssertFalse(RemoteModelFilter.isLikelySpeechToText("deepseek-r1-distill-llama-70b"))
    }

    func testTTSModelsAreExcludedEvenWithAudioNames() {
        // Groq lists playai-tts; speaches serves kokoro — TTS, not transcription.
        XCTAssertFalse(RemoteModelFilter.isLikelySpeechToText("playai-tts"))
        XCTAssertFalse(RemoteModelFilter.isLikelySpeechToText("kokoro-tts"))
        XCTAssertFalse(RemoteModelFilter.isLikelySpeechToText("tts-1-hd"))
        // The tts marker wins even when an stt marker is also present.
        XCTAssertFalse(RemoteModelFilter.isLikelySpeechToText("whisper-tts-hybrid"))
    }
}
