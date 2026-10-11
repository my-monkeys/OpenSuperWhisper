import AVFoundation
import Foundation
import Metal
import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Files tracked at the repository root that tests read in place.
///
/// Resolved through `#filePath` rather than the test bundle, so nothing has to be copied into
/// it. Kept in one place because the plan moves tests into a core target that sits at another
/// depth: the lookup then changes here and nowhere else.
enum Fixtures {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 11 s of JFK's inaugural address, 16 kHz mono.
    static let jfkWav = repoRoot.appendingPathComponent("jfk.wav")

    /// The smallest English Whisper model, about 75 MB.
    static let tinyEnModel = repoRoot.appendingPathComponent("ggml-tiny.en.bin")
}

extension Fixtures {
    static let whisperSampleRate = 16000

    /// Decodes a fixture the way every local engine does before inference, so a test that
    /// builds audio around it starts from the same 16 kHz mono samples the engine would.
    static func whisperSamples(of url: URL) async throws -> [Float] {
        guard let samples = try await AudioPCMConverter.convertAudioToPCM(fileURL: url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return samples
    }

    /// Writes 16 kHz mono float samples to a new WAV file in the temporary directory. The engines
    /// only take file URLs, so audio built in code has to go through disk. The caller deletes it.
    static func writeWhisperWav(_ samples: [Float], name: String) throws -> URL {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(whisperSampleRate),
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// Everything that reaches the engine pinned to fixed values, so no preference the test
    /// process happens to hold can change a transcript. The values are the app's defaults for a
    /// fresh install, with English chosen explicitly and every prompt source empty.
    static func pinnedSettings(showTimestamps: Bool = false) -> Settings {
        var settings = Settings()
        settings.selectedLanguage = "en"
        settings.translateToEnglish = false
        settings.suppressBlankAudio = true
        settings.showTimestamps = showTimestamps
        settings.temperature = 0
        settings.noSpeechThreshold = 0.6
        settings.initialPrompt = ""
        settings.useBeamSearch = false
        settings.beamSize = 5
        settings.useAsianAutocorrect = true
        settings.customDictionaryEnabled = false
        settings.customDictionaryBoostEnabled = false
        settings.customDictionaryEntries = []
        settings.useSurroundingTextAsContext = false
        settings.focusedText = nil
        return settings
    }
}

extension Fixtures {
    /// Skips a test whose expected output was recorded on an Apple Silicon Mac with its Metal GPU
    /// (the Whisper goldens and the exact VAD boundaries). ggml picks its kernels from the CPU
    /// and the GPU, so another machine can produce other strings for reasons unrelated to any
    /// code change: an Intel or Rosetta build, a VM whose GPU is virtual or missing (CI's macos
    /// runners). `OSW_GOLDEN_MACHINE=0`, passed as `TEST_RUNNER_OSW_GOLDEN_MACHINE=0` through
    /// xcodebuild, skips them on purpose; a strict local run leaves it unset and enforces them.
    static func requireGoldenMachine() throws {
        if ProcessInfo.processInfo.environment["OSW_GOLDEN_MACHINE"] == "0" {
            throw XCTSkip("OSW_GOLDEN_MACHINE=0: recorded outputs are not enforced on this machine")
        }
#if !arch(arm64)
        throw XCTSkip("Recorded on arm64; this build runs other CPU kernels")
#else
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device; whisper would run on the CPU only")
        }
        // Apple7 is the M1 family and up. A virtual GPU that reports no Apple family is skipped
        // here; one that claims a family needs OSW_GOLDEN_MACHINE=0.
        guard device.supportsFamily(.apple7) else {
            throw XCTSkip("Metal device \(device.name) is not an Apple Silicon GPU")
        }
#endif
    }
}
