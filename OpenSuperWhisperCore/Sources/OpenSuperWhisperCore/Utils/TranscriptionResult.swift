import Foundation

public enum TranscriptionResult {
    /// Returned by the engines when nothing intelligible was transcribed. It is shown to the
    /// user as feedback but never pasted into the focused field.
    public static let noSpeech = "No speech detected in the audio"
}
