import Foundation

/// Recording-lifecycle seam (plan interface contract). Matches the existing macOS
/// `AudioRecorder` surface so current and future core code can depend on the
/// abstraction; macOS conformance arrives via app-side extension, the iOS
/// implementation at Cycle 2.
public protocol AudioRecording: AnyObject {
    func startRecording()
    func stopRecording() -> URL?
    func cancelRecording()
    func moveTemporaryRecording(from tempURL: URL, to finalURL: URL) throws
    func playRecording(url: URL)
    func stopPlaying()
}
