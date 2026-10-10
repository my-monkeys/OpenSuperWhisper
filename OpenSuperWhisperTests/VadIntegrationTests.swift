import AVFoundation
import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Proves the VAD gate works end to end: the Silero model is in the bundle, it loads, and it
/// finds real speech where the speech actually is.
///
/// The trimming unit tests can't show any of that — they exercise a pure function over
/// hand-written segments and stay green even if the model never ships or never loads. Three
/// bugs in this app shipped exactly that way, so this one uses real audio.
final class VadIntegrationTests: XCTestCase {

    private let sampleRate: Double = 16000
    private let leadingSilence: Double = 2.0

    /// Speech synthesised at test time (no audio fixture in the repo), padded with silence so
    /// there is something for the VAD to cut.
    private func makeFixture() throws -> (samples: [Float], speechEnd: Double) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let aiff = dir.appendingPathComponent("say.aiff")
        try run("/usr/bin/say", ["-o", aiff.path,
                                 "This is a dictation test for voice activity detection."])
        let wav = dir.appendingPathComponent("say.wav")
        try run("/usr/bin/afconvert",
                ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])

        let speech = try read(wav)
        let silence = [Float](repeating: 0, count: Int(leadingSilence * sampleRate))
        let speechSeconds = Double(speech.count) / sampleRate
        return (silence + speech + silence, leadingSilence + speechSeconds)
    }

    private func run(_ launchPath: String, _ arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            throw XCTSkip("\(launchPath) unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(launchPath) failed")
        }
    }

    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: sampleRate, channels: 1,
                                                 interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                         count: Int(buffer.frameLength)))
    }

    func testFindsSpeechInRealAudioAndCutsTheSilence() throws {
        let path = try XCTUnwrap(WhisperEngine.vadModelPath,
                                 "ggml-silero-v5.1.2.bin is not in the app bundle")
        let vad = try XCTUnwrap(MyWhisperVadContext(modelPath: path),
                                "the bundled Silero model failed to load")

        let fixture = try makeFixture()
        let segments = try XCTUnwrap(vad.speechSegments(in: fixture.samples,
                                                        minSpeechMs: 100, padMs: 100))

        XCTAssertFalse(segments.isEmpty, "no speech found in a clip that is mostly speech")
        XCTAssertEqual(Double(segments[0].startCs) / 100, leadingSilence, accuracy: 0.5,
                       "speech located somewhere other than where it was put")
        XCTAssertEqual(Double(segments.last!.endCs) / 100, fixture.speechEnd, accuracy: 0.5)

        let trimmed = WhisperEngine.speechOnlySamples(from: fixture.samples, segments: segments)
        let keptSeconds = Double(trimmed.count) / sampleRate
        let speechSeconds = fixture.speechEnd - leadingSilence

        XCTAssertEqual(keptSeconds, speechSeconds, accuracy: 0.8,
                       "the silence should be gone and the speech kept")
        XCTAssertLessThan(trimmed.count, fixture.samples.count)
    }
}
