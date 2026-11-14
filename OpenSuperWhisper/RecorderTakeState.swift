import AVFoundation
import os

/// What the take in progress owns. A take starts off the main thread and is stopped on it, while
/// the connection timer and the recorder's delegate read the same fields from other queues, so
/// they live behind one lock. A stop landing mid-start used to free an `AVAudioRecorder` under the
/// thread still messaging it.
///
/// Read by copying a field out, then act on the copy: `stop()` blocks until the audio queue
/// drains, and nothing that can block, or call back into the recorder, may run under the lock.
struct RecorderTakeState {
    var recorder: AVAudioRecorder?
    var url: URL?
    var connectionTimer: DispatchSourceTimer?
    var activity: NSObjectProtocol?
}

typealias RecorderTakeLock = OSAllocatedUnfairLock<RecorderTakeState>
