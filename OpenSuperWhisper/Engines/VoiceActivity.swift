import AVFoundation
import os

/// Remembers when the microphone last carried speech, by loudness alone. Fed from the audio
/// tap's thread and read on the main actor, hence the lock.
final class VoiceActivity: @unchecked Sendable {
    /// RMS above this counts as speech: about -36 dBFS, well over a quiet room's floor and
    /// under a normal speaking voice at laptop-mic distance.
    static let speechRMS: Float = 0.016

    private let lock = OSAllocatedUnfairLock(initialState: ProcessInfo.processInfo.systemUptime)

    func reset() {
        lock.withLock { $0 = ProcessInfo.processInfo.systemUptime }
    }

    func observe(_ buffer: AVAudioPCMBuffer) {
        guard Self.rms(of: buffer) >= Self.speechRMS else { return }
        lock.withLock { $0 = ProcessInfo.processInfo.systemUptime }
    }

    /// Seconds since the last buffer loud enough to be speech.
    var silenceDuration: TimeInterval {
        ProcessInfo.processInfo.systemUptime - lock.withLock { $0 }
    }

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        return (sum / Float(count)).squareRoot()
    }
}
