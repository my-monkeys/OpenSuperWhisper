import AVFoundation
import Foundation
@testable import OpenSuperWhisper

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
