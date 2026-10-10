import AVFoundation
import XCTest
@testable import OpenSuperWhisper

/// Interfaces such as the Audient EVO 4 expose 4 inputs (2 mics + 2 loopback) with speech on
/// the first only. The recorder writes all four, and every engine must hear the one that carries
/// signal rather than AVAudioConverter's downmix of them (#213 upstream).
final class MultiChannelMixTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        tempFiles = []
        super.tearDown()
    }

    func testSpeechOnFirstOfFourChannelsKeepsItsLevel() async throws {
        let url = try writeFourChannelTone()
        let converted = try await AudioPCMConverter.convertAudioToPCM(fileURL: url)
        let samples = try XCTUnwrap(converted)
        XCTAssertEqual(Double(samples.count), 16000, accuracy: 200)
        XCTAssertEqual(rms(samples), Float(0.2 / 2.0.squareRoot()), accuracy: 0.01)
    }

    func testMonoFileIsLeftAlone() async throws {
        let url = try write(channels: 1) { _, _ in 0.1 }
        let mono = try await AudioPCMConverter.monoFileIfMultiChannel(url)
        XCTAssertNil(mono)
    }

    func testMultiChannelFileBecomesAMonoMix() async throws {
        let url = try writeFourChannelTone()
        let result = try await AudioPCMConverter.monoFileIfMultiChannel(url)
        let mono = try XCTUnwrap(result)
        tempFiles.append(mono)
        let file = try AVAudioFile(forReading: mono)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.processingFormat.sampleRate, 16000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        XCTAssertEqual(rms(samples), Float(0.2 / 2.0.squareRoot()), accuracy: 0.01)
    }

    /// Parakeet on jfk.wav placed on the first of four channels. Gated because it needs the
    /// Parakeet v3 models, which it downloads when they are missing.
    func testParakeetHearsSpeechOnFirstOfFourChannels() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OSW_TEST_FLUIDAUDIO"] == "1",
                          "Needs the Parakeet models")
        let source = try AVAudioFile(forReading: Fixtures.jfkWav)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(source.length)))
        try source.read(into: buffer)
        let speech = buffer.floatChannelData![0]
        let url = try write(channels: 4, sampleRate: source.processingFormat.sampleRate,
                            frames: Int(buffer.frameLength)) { channel, frame in
            channel == 0 ? speech[frame] : 0
        }
        let engine = FluidAudioEngine(versionOverride: "v3")
        try await engine.initialize()
        let text = try await engine.transcribeAudio(url: url, settings: Settings())
        XCTAssertTrue(text.lowercased().contains("your country"), text)
    }

    // MARK: - Helpers

    private func writeFourChannelTone() throws -> URL {
        try write(channels: 4) { channel, frame in
            let time = Double(frame) / 48000
            switch channel {
            case 0: return Float(0.2 * sin(time * 440 * 2 * .pi))
            case 1: return Float(0.00001 * sin(time * 97 * 2 * .pi))
            default: return 0
            }
        }
    }

    private func write(channels: Int, sampleRate: Double = 48000, frames: Int = 48000,
                       sample: (Int, Int) -> Float) throws -> URL {
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   interleaved: false, channelLayout: layout)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mix-\(channels)ch-\(UUID().uuidString).wav")
        tempFiles.append(url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            for frame in 0..<frames {
                buffer.floatChannelData![channel][frame] = sample(channel, frame)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func rms(_ samples: [Float]) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
    }
}
