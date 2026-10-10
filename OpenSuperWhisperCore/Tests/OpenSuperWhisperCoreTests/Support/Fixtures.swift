import AVFoundation
import Foundation
import Metal
import XCTest
@testable import OpenSuperWhisperCore

/// Files tracked in the repository that the core tests read in place.
///
/// Found through `#filePath`, so nothing is copied into the test bundle. The iOS Simulator runs as
/// the host user and reads the same absolute paths. `OSW_FIXTURES_ROOT` (passed as
/// `TEST_RUNNER_OSW_FIXTURES_ROOT` through xcodebuild) points at a copy of the three files instead,
/// for a run that a privacy prompt keeps out of the checkout's folder.
enum Fixtures {
    static let repoRoot: URL = {
        if let root = ProcessInfo.processInfo.environment["OSW_FIXTURES_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        // Support, OpenSuperWhisperCoreTests, Tests, OpenSuperWhisperCore, then the repository.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    /// 11 s of JFK's inaugural address, 16 kHz mono.
    static let jfkWav = repoRoot.appendingPathComponent("jfk.wav")

    /// The smallest English Whisper model, about 75 MB.
    static let tinyEnModel = repoRoot.appendingPathComponent("ggml-tiny.en.bin")

    /// The app's own copy of the Silero VAD model, read by path: the package ships no resources
    /// from its library target, and a second 0.9 MB copy would only drift.
    static let sileroVAD = repoRoot.appendingPathComponent("OpenSuperWhisper/ggml-silero-v5.1.2.bin")
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

    /// Everything that reaches the engine pinned to fixed values, so no preference can change a
    /// transcript. The same 15 values as the hosted helper: the app's fresh-install defaults,
    /// English chosen explicitly and every prompt source empty.
    static func pinnedSettings(showTimestamps: Bool = false) -> TranscriptionSettings {
        TranscriptionSettings(selectedLanguage: "en",
                              translateToEnglish: false,
                              suppressBlankAudio: true,
                              showTimestamps: showTimestamps,
                              temperature: 0,
                              noSpeechThreshold: 0.6,
                              initialPrompt: "",
                              useBeamSearch: false,
                              beamSize: 5,
                              useAsianAutocorrect: true,
                              customDictionaryEnabled: false,
                              customDictionaryBoostEnabled: false,
                              customDictionaryEntries: [],
                              useSurroundingTextAsContext: false,
                              focusedText: nil)
    }
}

extension Fixtures {
    /// Skips a test whose expected output was recorded on an Apple Silicon Mac with its Metal GPU.
    /// Same rule as the hosted helper: ggml picks its kernels from the CPU and the GPU, so another
    /// machine can produce other strings for reasons unrelated to any code change.
    /// `OSW_GOLDEN_MACHINE=0` skips on purpose. The simulator runs `.cpuOnly`, so it never
    /// reaches the Metal path these strings were recorded on.
    static func requireGoldenMachine() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("the simulator runs .cpuOnly")
#else
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
#endif
    }

    /// Skips a CPU-only output check away from the recording Mac. CPU strings can differ across
    /// Accelerate paths and CPU generations, so they are only promised where they were recorded.
    static func requireCPUGoldenMachine() throws {
        if ProcessInfo.processInfo.environment["OSW_GOLDEN_MACHINE"] == "0" {
            throw XCTSkip("OSW_GOLDEN_MACHINE=0: recorded outputs are not enforced on this machine")
        }
#if !arch(arm64)
        throw XCTSkip("Recorded on arm64; this build runs other CPU kernels")
#endif
    }
}
