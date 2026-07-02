import Foundation

/// Pauses/resumes system media playback via the private MediaRemote framework.
///
/// The pause is always sent **unconditionally** — a synchronous "is something playing?" probe at
/// record-start reads false, because starting `AVAudioRecorder` transiently clears the system Now
/// Playing flag (#126), so a probe there wrongly skips the pause (browser tabs like YouTube never
/// paused). A pause command is a harmless no-op when nothing plays, so this is safe and reliable.
///
/// The resume is where it gets subtle: we want to resume only what was actually playing, so an
/// idle/already-paused source isn't *woken* when recording stops. That requires reading the
/// now-playing state — but **MediaRemote gates now-playing reads on a real (team) code signature.**
/// Verified empirically: Apple's signed `swift` toolchain reads `IsPlaying=true`/`rate=1` for a
/// playing Chrome tab, while an ad-hoc/unsigned build (or subprocess) reads nothing back. So:
///
///   • Signed builds (reads work): poll the playback state while not recording, snapshot it at
///     pause, and resume only if it was playing. Idle media is left alone.
///   • Unsigned/ad-hoc builds (reads fail): we can't tell what was playing, so leave playback
///     paused (the user presses play to resume). We deliberately do NOT always-resume here: macOS
///     keeps stale/closed media as the now-playing owner, so always-resuming would frequently wake
///     things the user didn't know were "playing".
///
/// Which path is active is detected at runtime (`canRead`), so a properly signed release upgrades
/// to the precise behavior automatically with no code change. MediaRemote's now-playing is a single
/// system-wide owner, so this acts on the active player; it can't restore several sources at once.
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()

    /// Whether we armed a resume this cycle (something was playing when we paused, or we can't tell).
    private(set) var didPauseMedia = false

    /// Cached "is the Now Playing app playing?" (from the playback rate), refreshed while not
    /// recording so it reflects the state from *before* a recording disrupts the flag. Only
    /// meaningful when `canRead` is true.
    private var isNowPlaying = false

    /// Whether this process can actually read now-playing state (see the type doc — gated on a real
    /// code signature). Set true the first time a now-playing info dict comes back. While false we
    /// can't detect playback, so resume falls back to always-on (#126).
    private var canRead = false
    private var readAttempts = 0

    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1
    private static let pollInterval: TimeInterval = 1.5
    /// Give reads a few tries; if none succeed this build can't read now-playing (unsigned) — stop
    /// polling and settle into the always-resume fallback rather than polling forever.
    private static let maxReadAttempts = 5

    private let sendCommand: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool)?
    /// MRMediaRemoteGetNowPlayingInfo(queue, completion(infoDict?)). The dict is nil when this
    /// process can't read now-playing, which doubles as the capability signal.
    private let getInfo: (@convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void)?
    private var pollTimer: Timer?

    private init() {
        let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        )
        if let bundle,
           let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            sendCommand = unsafeBitCast(ptr, to: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool).self)
        } else {
            sendCommand = nil
        }
        if let bundle,
           let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            getInfo = unsafeBitCast(
                ptr, to: (@convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void).self)
        } else {
            getInfo = nil
        }

        // Prime the now-playing connection — reads don't work in signed builds without registering.
        if let bundle,
           let regPtr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
            unsafeBitCast(regPtr, to: RegisterFn.self)(DispatchQueue.main)
        }

        startPolling()
    }

    /// Poll the playing state while not recording (fires in `.common` mode so it keeps ticking
    /// during menu tracking / window resizing).
    private func startPolling() {
        guard getInfo != nil, pollTimer == nil else { return }
        refreshNowPlaying()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refreshNowPlaying()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshNowPlaying() {
        // If reads never succeed, this build can't see now-playing — stop polling and rely on the
        // always-resume fallback.
        if !canRead {
            readAttempts += 1
            if readAttempts > Self.maxReadAttempts { stopPolling(); return }
        }
        getInfo?(DispatchQueue.main) { [weak self] info in
            guard let self, let dict = info as? [String: Any] else { return }
            self.canRead = true
            let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
            self.isNowPlaying = rate > 0
        }
    }

    /// Pause playback (unconditional = reliable), arming a resume only if something was actually
    /// playing when we paused (or unconditionally when we can't read state), and freezing the cache
    /// while the recording runs.
    func pauseMedia() {
        guard let sendCommand else { return }
        // Can read → resume only what was playing. Can't read (unsigned) → leave it paused: macOS
        // keeps stale/closed media (e.g. the last YouTube video) as the now-playing owner, so
        // always-resuming would frequently wake things the user didn't know were "playing".
        let wasPlaying = canRead ? isNowPlaying : false
        stopPolling()
        _ = sendCommand(Self.kMRPause, nil)
        didPauseMedia = wasPlaying
    }

    /// Resume playback, but only if we paused something this cycle; then re-arm the poll (only if
    /// reads work — otherwise we've settled into the fallback and there's nothing to poll).
    func resumeMedia() {
        defer { if canRead { startPolling() } }
        guard didPauseMedia, let sendCommand else { return }
        _ = sendCommand(Self.kMRPlay, nil)
        didPauseMedia = false
    }
}
