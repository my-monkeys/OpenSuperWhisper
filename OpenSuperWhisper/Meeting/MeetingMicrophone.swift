import AVFoundation

/// Your side of a meeting: the microphone, with Apple's voice processing on so the call coming
/// out of the speakers is cancelled from it (#159). Without that, everything the others say
/// would also land on the "Me" track whenever there are no headphones.
final class MeetingMicrophone {
    private let engine = AVAudioEngine()

    func start(writingTo writer: MeetingTrackWriter) throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // Voice processing lowers every other app's sound by default, which in a meeting is the
        // call itself.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        // The node's own format, exactly: anything else raises an Objective-C exception that
        // takes the app down (see installTap in AudioRecorder).
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.write(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }
}
