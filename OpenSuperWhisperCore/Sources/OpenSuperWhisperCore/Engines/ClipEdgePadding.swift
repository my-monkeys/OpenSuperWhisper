import Foundation

/// Silence put around a dictation before Parakeet hears it; the file on disk is left as it was.
///
/// A take begins on the key press and ends on the release, so it often opens or closes in the
/// middle of a word. With no quiet on either side, Parakeet drops or garbles that word. On 25
/// real takes that ended with the speaker still talking, 17 transcripts changed once padded, and
/// the changes were nearly all a first or last word coming back. Padding one side only recovered
/// fewer than both.
enum ClipEdgePadding {
    static let sampleRate = 16_000
    static let leadingSeconds = 0.3
    static let trailingSeconds = 0.8
    /// Longer files are meetings or imports. FluidAudio streams them from disk, and their edges
    /// are too small a part of the whole to be worth loading them into memory to pad.
    static let maximumClipSeconds: Double = 300

    static func fits(durationSeconds: Double) -> Bool {
        durationSeconds <= maximumClipSeconds
    }

    static func padded(_ samples: [Float]) -> [Float] {
        silence(seconds: leadingSeconds) + samples + silence(seconds: trailingSeconds)
    }

    private static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }
}
