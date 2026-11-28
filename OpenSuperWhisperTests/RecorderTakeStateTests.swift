import XCTest
import os

@testable import OpenSuperWhisper

/// The take state is written by a start off the main thread, a stop on it, the connection timer
/// and the recorder's delegate. Losing a recorder there freed it under another thread's message
/// send (a SIGSEGV in `objc_msgSend` from 0.15.2).
final class RecorderTakeStateTests: XCTestCase {

    func testStartIsKeptWhenItsTakeIsStillCurrent() {
        let url = URL(fileURLWithPath: "/tmp/rec-a.wav")
        XCTAssertFalse(AudioRecorder.startWasAbandoned(startedURL: url, currentURL: url))
    }

    func testStartIsAbandonedWhenAnotherTakeReplacedIt() {
        let url = URL(fileURLWithPath: "/tmp/rec-a.wav")
        let next = URL(fileURLWithPath: "/tmp/rec-b.wav")
        XCTAssertTrue(AudioRecorder.startWasAbandoned(startedURL: url, currentURL: next))
    }

    func testStartIsAbandonedWhenTheTakeWasCleared() {
        let url = URL(fileURLWithPath: "/tmp/rec-a.wav")
        XCTAssertTrue(AudioRecorder.startWasAbandoned(startedURL: url, currentURL: nil))
    }

    /// The other side of the same question: not "may this start continue?" but "may it clean up?".
    /// A start can fail while a stop, or a whole new take, lands during the blocking mic switch.
    /// Its cleanup may then release only state it still owns: releasing a newer take's URL and App
    /// Nap assertion would silently discard that take's recording. (#360 review)
    func testAnAbortedStartReleasesOnlyATakeItStillOwns() {
        let mine = URL(fileURLWithPath: "/tmp/mine.wav")
        let newer = URL(fileURLWithPath: "/tmp/newer.wav")
        // Still this start's, or already released by a stop: nothing of another take to clobber.
        XCTAssertTrue(AudioRecorder.canReleaseAbortedStart(startedURL: mine, currentURL: mine))
        XCTAssertTrue(AudioRecorder.canReleaseAbortedStart(startedURL: mine, currentURL: nil))
        // A newer take owns the URL and the assertion: this start must leave both alone.
        XCTAssertFalse(AudioRecorder.canReleaseAbortedStart(startedURL: mine, currentURL: newer))
    }

    /// Never a real recorder: the hosted runner must not open the microphone. An `NSObject`
    /// stands in, since what is under test is the lock, not the audio.
    func testConcurrentWritesAndReadsKeepReferencesAlive() {
        let lock = RecorderTakeLock(initialState: RecorderTakeState())
        let workers = 8
        let iterations = 5_000
        let seen = OSAllocatedUnfairLock(initialState: 0)

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for i in 0..<iterations {
                switch (worker + i) % 3 {
                case 0:
                    let token = NSObject()
                    lock.withLock { $0.activity = token }
                case 1:
                    let held = lock.withLock { state -> NSObjectProtocol? in
                        defer { state.activity = nil }
                        return state.activity
                    }
                    if held != nil { seen.withLock { $0 += 1 } }
                default:
                    let url = URL(fileURLWithPath: "/tmp/rec-\(worker)-\(i).wav")
                    lock.withLock { $0.url = url }
                    _ = lock.withLock { $0.url }?.lastPathComponent
                }
            }
        }
        XCTAssertGreaterThan(seen.withLock { $0 }, 0)
    }
}
