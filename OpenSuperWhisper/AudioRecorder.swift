import AVFoundation
import Foundation
import SwiftUI
import AppKit
import CoreAudio
import os
import OpenSuperWhisperCore

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentlyPlayingURL: URL?
    @Published var canRecord = false
    @Published var isConnecting = false
    
    private var audioPlayer: AVAudioPlayer?
    private var notificationSound: NSSound?
    /// The volume duck waiting for the start chime to finish. Cancelled by a stop that lands
    /// first, or the duck would fire after the restore and leave the Mac turned down.
    private var pendingDuck: DispatchWorkItem?
    private let temporaryDirectory: URL
    /// The take being written, which nothing else may touch until it is stopped.
    var currentRecordingURL: URL? { take.withLockUnchecked { $0.url } }
    private var notificationObserver: Any?
    private var microphoneChangeObserver: Any?
    /// The take in progress, behind its lock (see `RecorderTakeState`). Its `activity` holds App
    /// Nap off for as long as a recording is running, and is nil when nothing is recording.
    ///
    /// App Nap throttles timers and defers dispatch work for an app that is not frontmost and has
    /// no visible window — which describes every dictation, since the point of the app is to record
    /// while another app has focus. Playing audio holds App Nap off on its own; *recording* audio
    /// does not, so a recorder without an assertion gets suspended.
    ///
    /// That was #98. CoreAudio's I/O threads are real-time and carry on regardless, so the clip
    /// kept growing while everything meant to react to it stopped: the connection wait never
    /// ticked, the `isConnecting`/`isRecording` updates sat unapplied on the main queue, and the
    /// trigger key did nothing. The bubble stayed up with no way to stop it, and force-quitting was
    /// the only way out. Locking the Mac or opening Sound settings to change input is simply how
    /// you end up backgrounded and occluded, which is why the bug looked like it was about
    /// switching devices.
    ///
    /// Idle *system* sleep is deliberately left enabled: a recording that somehow never ends should
    /// not also keep the Mac awake for ever.
    private let take = RecorderTakeLock(initialState: RecorderTakeState())

    // MARK: - Singleton Instance

    static let shared = AudioRecorder()
    
    override private init() {
        let tempDir = FileManager.default.temporaryDirectory
        temporaryDirectory = tempDir.appendingPathComponent("temp_recordings")
        
        super.init()
        createTemporaryDirectoryIfNeeded()
        setup()
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = microphoneChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setup() {
        updateCanRecordStatus()

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        microphoneChangeObserver = NotificationCenter.default.addObserver(
            forName: .microphoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
    }

    private func updateCanRecordStatus() {
        canRecord = MicrophoneService.shared.getActiveMicrophone() != nil
    }

    private func createTemporaryDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            // Takes are recorded here rather than in the system temp folder, so a crash leaves
            // them where the next launch looks.
            try FileManager.default.createDirectory(at: UnfinishedDictations.directory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create temporary recordings directory: \(error)")
        }
    }
    
    /// The short chime used to confirm a recording state change. Internal rather than private so
    /// the Space latch can reuse it — same class of feedback, same preference.
    /// Which chime to play. The end of a take used to reuse the start chime, which sounded like a
    /// new recording beginning; the stop chime is the same note a fourth lower.
    enum Chime: String {
        case start = "notification"
        case stop = "notification-stop"
    }

    /// How long the chime is worth hearing before the volume may drop. The file runs about
    /// 1.8 s, silence included, and waiting for all of it left the room loud well into the
    /// take. Measured, the note has faded by about 20 dB at 150 ms.
    static let chimeAudibleLength: TimeInterval = 0.15

    func playNotificationSound(_ chime: Chime = .start) {
        // Try to play using NSSound first
        guard let soundURL = Bundle.main.url(forResource: chime.rawValue, withExtension: "mp3") else {
            print("Failed to find notification sound file")
            // Fall back to system sound if notification.mp3 is not found
            NSSound.beep()
            return
        }
        
        if let sound = NSSound(contentsOf: soundURL, byReference: false) {
            // Set maximum volume to ensure it's audible
            sound.volume = 0.3
            sound.play()
            notificationSound = sound
        } else {
            print("Failed to create NSSound from URL, falling back to system beep")
            // Fall back to system beep if NSSound creation fails
            NSSound.beep()
        }
    }
    
    /// Tells the system this app is doing work the user asked for, so App Nap leaves it alone.
    /// See `take.activity`. Ending any assertion already held keeps them from stacking: a
    /// start that never saw a matching stop would otherwise leak one and hold App Nap off for good.
    /// Internal rather than private so a test can check the pair stays balanced.
    func beginRecordingActivity() {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Recording audio for dictation")
        let previous = take.withLockUnchecked { state -> NSObjectProtocol? in
            defer { state.activity = activity }
            return state.activity
        }
        previous.map(ProcessInfo.processInfo.endActivity)
    }

    /// Releases the assertion. Safe to call when none is held, which is what makes it usable both
    /// on every exit path and as the guard against stacking in `beginRecordingActivity`.
    func endRecordingActivity() {
        let activity = take.withLockUnchecked { state -> NSObjectProtocol? in
            defer { state.activity = nil }
            return state.activity
        }
        activity.map(ProcessInfo.processInfo.endActivity)
    }

    /// Whether an assertion is currently held. Exists so a test can check that starting and
    /// stopping a recording leaves none behind.
    var isHoldingRecordingActivity: Bool { take.withLockUnchecked { $0.activity != nil } }

    /// Why a start cannot even be attempted, nil when it can. Said to the bubble, which has
    /// already shown "recording": without it the bubble stayed on that until the user stopped it.
    static func startBlocker(canRecord: Bool, microphoneAccess: AVAuthorizationStatus) -> String? {
        guard canRecord else { return String(localized: "No microphone available") }
        switch microphoneAccess {
        case .denied, .restricted:
            return String(localized: "OpenSuperWhisper can't hear you until you allow the microphone in System Settings.")
        default:
            return nil
        }
    }

    /// Why a take cannot go ahead when the system input would not switch to the chosen
    /// microphone, nil when it did. Left ignored, the take recorded from whatever macOS still
    /// used — silent on a closed laptop lid — and a silent clip is deleted as "no speech", so
    /// the user had nothing to go on (#360).
    static func microphoneSwitchBlocker(switched: Bool) -> String? {
        guard !switched else { return nil }
        return String(localized: "Couldn't use the selected microphone. Check that it's connected and try again.")
    }

    /// Clears the recording state and puts the reason where the user is looking. Not routed
    /// through `flash`: the bubble is waiting on this very recording.
    private func reportStartFailure(_ message: String) {
        updateRecordingState(isRecording: false, isConnecting: false)
        Task { @MainActor in IndicatorWindowManager.shared.reportRecordingFailure(message) }
    }

    /// Starts the recording in a detached task and returns at once; false when there is no input
    /// device. The hotkey path calls it before the caret lookup, the indicator and the context
    /// capture, which cost 25-60ms on the main thread (more for a browser URL), and every word
    /// spoken in that time is lost.
    func startRecordingInBackground(pressedAt: DispatchTime? = nil) -> Bool {
        // `getActiveMicrophone()` reads the cached device, so this stays off the blocking
        // AVFoundation path that the hotkey tap must avoid (#freeze).
        guard MicrophoneService.shared.getActiveMicrophone() != nil else { return false }
        Task.detached { [self] in startRecording(pressedAt: pressedAt) }
        return true
    }

    /// `pressedAt` is when the trigger key went down, for the log line that says how long the
    /// microphone took to open after it.
    func startRecording(pressedAt: DispatchTime? = nil) {
        Diag.mark("recorder.startRecording (canRecord=\(canRecord))")
        if let blocker = Self.startBlocker(canRecord: canRecord,
                                           microphoneAccess: AVCaptureDevice.authorizationStatus(for: .audio)) {
            print("Cannot start recording: \(blocker)")
            reportStartFailure(blocker)
            return
        }

        if isRecording || isConnecting {
            print("stop recording while recording")
            _ = stopRecording()
        }

        // Before any of the audio setup, so the connection wait and the state updates that follow
        // are already protected from being throttled. (#98)
        beginRecordingActivity()

        // A UUID suffix keeps each recording's temp file unique. Without it, two recordings
        // started in the same wall-clock second share a path — and starting the next recording
        // would truncate the previous clip's file while the background pipeline is still reading
        // it to transcribe. (parallel-recording)
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "rec-\(timestamp)-\(UUID().uuidString.prefix(8)).wav"
        let fileURL = UnfinishedDictations.directory.appendingPathComponent(filename)
        take.withLockUnchecked { $0.url = fileURL }

        print("start record file to \(fileURL)")

        #if os(macOS)
        if let activeMic = MicrophoneService.shared.getActiveMicrophone() {
            // A failed switch would record from whatever macOS still uses instead of the
            // microphone the user chose, so the take must not start at all. (#360)
            let switched = Diag.measure("setAsSystemDefaultInput") {
                MicrophoneService.shared.setAsSystemDefaultInput(activeMic)
            }
            if let blocker = Self.microphoneSwitchBlocker(switched: switched) {
                print("Cannot start recording: \(blocker)")
                // No stop follows a start that never happened, so the take and the App Nap
                // assertion are released here or they are held for ever.
                take.withLockUnchecked { $0.url = nil }
                endRecordingActivity()
                reportStartFailure(blocker)
                return
            }
            print("Set system default input to: \(activeMic.displayName)")
        }
        #endif

        let requiresConnection = Diag.measure("isActiveMicrophoneRequiresConnection") {
            MicrophoneService.shared.isActiveMicrophoneRequiresConnection()
        }
        // Which device a take ran on, whether it has to connect first and how many of its
        // channels are recorded: the facts that pick the start path and the file's format, and
        // the first worth knowing from a report of a take going wrong.
        let channels = recordingChannels()
        Diag.mark("recorder.device=\(MicrophoneService.shared.getActiveMicrophone()?.displayName ?? "none") "
            + "requiresConnection=\(requiresConnection) channels=\(channels.description)")
        updateRecordingState(isRecording: false, isConnecting: requiresConnection)
        startRecordingWithRecorder(fileURL: fileURL, channelCount: channels.recorded,
                                   monitorConnection: requiresConnection)

        // After the mic is open: pausing media, the chime and the duck cost ~100ms that would
        // otherwise sit between the key press and the first captured sample. A failed start has
        // no stop to undo them, so it skips them.
        guard currentRecordingURL != nil else { return }
        if let pressedAt {
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- pressedAt.uptimeNanoseconds) / 1_000_000
            Diag.mark("key press -> recording started after \(Int(ms.rounded())) ms")
        }
        if AppPreferences.shared.pauseMediaOnRecord {
            Diag.measure("media.pause") { MediaPlaybackController.shared.pauseMedia() }
        }
        // Chime first, then lower the volume: ducked first, the start chime would play at the
        // ducked level, 10% by default, and be inaudible, while the end chime plays after the
        // restore.
        var chimeLength: TimeInterval = 0
        if AppPreferences.shared.playSoundOnRecordStart {
            Diag.measure("chime.start") { playNotificationSound() }
            chimeLength = Self.chimeAudibleLength
        }
        if AppPreferences.shared.reduceVolumeOnRecord {
            let level = Float32(AppPreferences.shared.reduceVolumeLevel)
            // Checked when it fires: a take stopped meanwhile has already restored the volume.
            let duck = DispatchWorkItem { [weak self] in
                guard self?.currentRecordingURL != nil else { return }
                SystemVolumeController.shared.duck(toFractionOf: level)
            }
            DispatchQueue.main.async { [weak self] in
                self?.pendingDuck?.cancel()
                self?.pendingDuck = duck
                DispatchQueue.main.asyncAfter(deadline: .now() + chimeLength, execute: duck)
            }
        }
    }

    struct ChannelChoice {
        let recorded: Int
        let reported: Int
        let isBuiltIn: Bool

        var description: String { "\(recorded)/\(reported)\(isBuiltIn ? " builtIn" : "")" }
    }

    /// How many channels to ask the recorder for. A multi-input interface (an Audient EVO 4: two
    /// mics and two loopback) can carry the speech on any one of its inputs, so all of them are
    /// recorded and the converter mixes the ones with signal. The built-in mic is the opposite
    /// case. It normally reports one processed channel, but a stuck coreaudiod (seen on a macOS
    /// 27.2 beta, cleared by restarting it) made it report three raw capsules that recorded
    /// 25-30 dB too quiet, and System Settings' own meter barely moved either. One channel is
    /// enough for speech in both states, and the core lifts a clip that is still too quiet
    /// (`QuietClipGain`).
    static func recordingChannelCount(isBuiltIn: Bool, reportedChannels: Int) -> Int {
        isBuiltIn ? 1 : max(reportedChannels, 1)
    }

    private func recordingChannels() -> ChannelChoice {
        let service = MicrophoneService.shared
        guard let activeMic = service.getActiveMicrophone() else {
            return ChannelChoice(recorded: 1, reported: 1, isBuiltIn: false)
        }
        let isBuiltIn = service.hasBuiltInTransport(activeMic)
        let reported = service.getInputChannelCount(for: activeMic)
        return ChannelChoice(
            recorded: Self.recordingChannelCount(isBuiltIn: isBuiltIn, reportedChannels: reported),
            reported: reported, isBuiltIn: isBuiltIn)
    }

    private func startRecordingWithRecorder(fileURL: URL, channelCount: Int, monitorConnection: Bool) {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]
        
        do {
            let recorder = try Diag.measure("AVAudioRecorder init+record") { () throws -> AVAudioRecorder in
                let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
                recorder.delegate = self
                // Always on: the bubble reads it to notice a microphone that hears nothing.
                recorder.isMeteringEnabled = true
                // Published before `record()` so a stop landing meanwhile can reach it.
                take.withLockUnchecked { $0.recorder = recorder }
                recorder.record()
                return recorder
            }
            if abandonStartIfEnded(recorder, fileURL: fileURL) { return }
            Task { @MainActor in SpectrumAnalyzer.shared.start() }
            if monitorConnection {
                startConnectionMonitoring()
            } else {
                updateRecordingState(isRecording: true, isConnecting: false)
            }
            print("Recording started successfully")
        } catch {
            print("Failed to start recording: \(error)")
            take.withLockUnchecked { $0.url = nil }
            // No recording to protect, and nothing will call `stopRecording` for a start that
            // never happened — so release the assertion here or it is held for ever.
            endRecordingActivity()
            reportStartFailure(String(localized: "Recording could not start"))
        }
    }
    
    /// Whether a start finds its take already ended: a stop, a cancel or the delegate cleared the
    /// URL while the recorder was being made, or the next take has replaced it.
    static func startWasAbandoned(startedURL: URL, currentURL: URL?) -> Bool {
        currentURL != startedURL
    }

    /// Cleans up after a start that a stop beat to it. The recorder it just began is an orphan
    /// that nobody will stop, so it would keep the microphone open and write a file for good.
    private func abandonStartIfEnded(_ recorder: AVAudioRecorder, fileURL: URL) -> Bool {
        // A newer take keeps its own activity, so it is not touched for it.
        let orphan = take.withLockUnchecked { state -> (abandoned: Bool, activity: NSObjectProtocol?) in
            guard Self.startWasAbandoned(startedURL: fileURL, currentURL: state.url) else { return (false, nil) }
            if state.recorder === recorder { state.recorder = nil }
            guard state.url == nil else { return (true, nil) }
            defer { state.activity = nil }
            return (true, state.activity)
        }
        guard orphan.abandoned else { return false }
        recorder.stop()
        try? FileManager.default.removeItem(at: fileURL)
        orphan.activity.map(ProcessInfo.processInfo.endActivity)
        Diag.mark("recorder.start abandoned: stopped during start")
        return true
    }

    /// The loudest sample since the last reading, in dBFS, across the recorded channels; nil
    /// while nothing records.
    func peakPowerDBFS() -> Float? {
        guard let recorder = take.withLockUnchecked({ $0.recorder }), recorder.isRecording else { return nil }
        recorder.updateMeters()
        let channels = Int(recorder.format.channelCount)
        return (0..<max(channels, 1)).map { recorder.peakPower(forChannel: $0) }.max()
    }

    /// What a stop produced. A clip and an accidental tap used to be the same `nil`, so a
    /// recording that captured nothing ended as quietly as one the user never meant to make,
    /// and the only signal was noticing afterwards that the words were missing (#117).
    enum StopOutcome {
        case clip(URL)
        /// Real audio, just too little of it. Dropped without a word, as it always has been:
        /// a brushed trigger key should not queue an empty clip or flash a message.
        case tooShort
        /// No audio at all, so the take never began. The user spoke into nothing and has to be
        /// told, because unlike a brushed key this one costs them what they said.
        case noAudio

        var url: URL? {
            if case .clip(let url) = self { return url }
            return nil
        }

        /// Classify a finished take from what it produced. Pure, so the boundary between "we
        /// heard nothing" and "you brushed the key" is pinned by tests instead of only being
        /// exercised by a real recorder against a real microphone.
        ///
        /// A duration of zero covers both a file with no samples and one the player cannot
        /// open: neither holds anything to transcribe, and handing the second to the engine
        /// only moves the failure somewhere with less context.
        static func of(url: URL?, duration: TimeInterval) -> StopOutcome {
            guard let url, duration > 0 else { return .noAudio }
            return duration < AudioRecorder.minimumUsableDuration ? .tooShort : .clip(url)
        }
    }

    /// Below this, a take is treated as an accidental trigger press rather than a dictation.
    static let minimumUsableDuration: TimeInterval = 1.0

    func stopRecording() -> StopOutcome {
        // Runs on the main thread (IndicatorViewModel is @MainActor). AudioQueueStop waits for the
        // queue to drain, so an input device pulled out from under it could stall the app here —
        // timed so a `▶` with no `◀` would name it rather than leaving a silent freeze.
        let recorder = take.withLockUnchecked { state -> AVAudioRecorder? in
            defer { state.recorder = nil }
            return state.recorder
        }
        Diag.measure("AVAudioRecorder.stop") { recorder?.stop() }
        endRecordingActivity()

        updateRecordingState(isRecording: false, isConnecting: false)
        Task { @MainActor in SpectrumAnalyzer.shared.stop() }
        stopConnectionMonitoring()

        if AppPreferences.shared.pauseMediaOnRecord {
            MediaPlaybackController.shared.resumeMedia()
        }
        if AppPreferences.shared.reduceVolumeOnRecord {
            cancelPendingDuck()
            SystemVolumeController.shared.restore()
        }

        let url = take.withLockUnchecked { state -> URL? in
            defer { state.url = nil }
            return state.url
        }

        let duration = url.flatMap { try? AVAudioPlayer(contentsOf: $0).duration } ?? 0
        let outcome = StopOutcome.of(url: url, duration: duration)
        if outcome.url == nil, let url {
            try? FileManager.default.removeItem(at: url)
        }
        if case .noAudio = outcome {
            Diag.mark("recorder.stop - no audio captured, clip discarded")
        }
        // Only a take that goes on to be transcribed gets the end chime: a brushed key stays as
        // silent as it always was, and a cancel is not a stop.
        if outcome.url != nil, AppPreferences.shared.playSoundOnRecordStop {
            playNotificationSound(.stop)
        }
        return outcome
    }

    private func cancelPendingDuck() {
        DispatchQueue.main.async { [weak self] in
            self?.pendingDuck?.cancel()
            self?.pendingDuck = nil
        }
    }

    func cancelRecording() {
        // Same blocking AudioQueueStop as `stopRecording`, timed for the same reason.
        let recorder = take.withLockUnchecked { state -> AVAudioRecorder? in
            defer { state.recorder = nil }
            return state.recorder
        }
        Diag.measure("AVAudioRecorder.stop (cancel)") { recorder?.stop() }
        endRecordingActivity()
        updateRecordingState(isRecording: false, isConnecting: false)
        Task { @MainActor in SpectrumAnalyzer.shared.stop() }
        stopConnectionMonitoring()

        if AppPreferences.shared.pauseMediaOnRecord {
            MediaPlaybackController.shared.resumeMedia()
        }
        if AppPreferences.shared.reduceVolumeOnRecord {
            cancelPendingDuck()
            SystemVolumeController.shared.restore()
        }
        
        let url = take.withLockUnchecked { state -> URL? in
            defer { state.url = nil }
            return state.url
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    
    func moveTemporaryRecording(from tempURL: URL, to finalURL: URL) throws {

        let directory = finalURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }
    
    func playRecording(url: URL) {
        // Stop current playback if any
        stopPlaying()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
            currentlyPlayingURL = url
        } catch {
            print("Failed to play recording: \(error), url: \(url)")
            isPlaying = false
            currentlyPlayingURL = nil
        }
    }
    
    func stopPlaying() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentlyPlayingURL = nil
    }
    
    private func updateRecordingState(isRecording: Bool, isConnecting: Bool) {
        DispatchQueue.main.async {
            self.isRecording = isRecording
            self.isConnecting = isConnecting
        }
    }
    
    /// How long to wait for a microphone that needs to connect before showing the recording as
    /// live anyway.
    ///
    /// Bluetooth headsets take a moment to actually start delivering audio, which is what the
    /// wait is for. Three seconds is far longer than that and short enough that nobody sits
    /// through it wondering whether the app heard them.
    static let connectionGracePeriod: TimeInterval = 3.0

    /// Whether to stop waiting and treat the recording as live.
    ///
    /// The growth check alone had no way out. If the file never grew — a device that went away
    /// while the Mac was locked, an input that delivers nothing — the app waited forever: the
    /// bubble was up, `isRecording` stayed false, and only force-quitting recovered it (#98).
    ///
    /// Timing out into "live" rather than into a failure is deliberate. The recorder is running
    /// either way and the person is already talking, so giving up would throw their words away
    /// to fix a state problem. The worst case here is a silent recording they can stop, look at,
    /// and try again — which is what every microphone that does not need connecting already does.
    static func shouldGoLive(growthObservations: Int, elapsed: TimeInterval) -> Bool {
        growthObservations >= 2 || elapsed >= connectionGracePeriod
    }

    /// Peak level below which the recorder's meter is reading digital silence.
    ///
    /// `AVAudioRecorder` metering bottoms out at -160 dBFS for samples that are exactly zero,
    /// while a live microphone in a quiet room sits around -60 to -90. The floor is far under
    /// any real input and far above the metering floor, so only true zeros fall below it.
    static let silenceFloorDBFS: Float = -140

    /// Whether the meter shows audio from a microphone rather than zeros.
    ///
    /// A Bluetooth headset switching into its call profile delivers digital silence for 1.5 to
    /// 2.75 s while the file grows as fast as ever, so growth alone made the wait end at once and
    /// the bubble claim "recording" over words that were being lost (#340). nil means the meter
    /// could not be read, which is not evidence of signal.
    static func heardSignal(peakDBFS: Float?) -> Bool {
        guard let peakDBFS else { return false }
        return peakDBFS > silenceFloorDBFS
    }

    private func startConnectionMonitoring() {
        stopConnectionMonitoring()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        let initialFileSize: Int64 = 4096
        let startedAt = Date()
        var growthCount = 0

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let (recorder, url) = self.take.withLockUnchecked { ($0.recorder, $0.url) }
            guard recorder != nil, let url else {
                // The take ended before this timer was stored, so no stop will cancel it.
                if url == nil { timer.cancel() }
                return
            }

            let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let totalGrowth = currentFileSize - initialFileSize

            let peak = self.peakPowerDBFS()
            if totalGrowth > 8000, Self.heardSignal(peakDBFS: peak) {
                growthCount += 1
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            guard Self.shouldGoLive(growthObservations: growthCount, elapsed: elapsed) else { return }

            if growthCount < 2 {
                Diag.mark("recorder.connectionWait timed out after \(Int(elapsed * 1000))ms "
                    + "with \(totalGrowth) bytes written, peak \(peak.map { "\(Int($0))dBFS" } ?? "n/a"); "
                    + "going live anyway")
            }
            // Published from the main queue, after checking the take is still this one. This block
            // runs on a background queue: a stop landing just after the guard above would publish
            // `isRecording = false` and then have this one overwrite it with true, leaving the
            // bubble recording a take that had ended.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentRecordingURL == url else { return }
                self.stopConnectionMonitoring()
                self.isRecording = true
                self.isConnecting = false
            }
        }
        take.withLockUnchecked { $0.connectionTimer = timer }
        timer.resume()
    }

    private func stopConnectionMonitoring() {
        let timer = take.withLockUnchecked { state -> DispatchSourceTimer? in
            defer { state.connectionTimer = nil }
            return state.connectionTimer
        }
        timer?.cancel()
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        Diag.mark("recorder.didFinishRecording failed - clip discarded")

        // Clearing the URL is also what the connection wait guards on, so on its own it left that
        // timer running at 20Hz with nothing to measure and no way to reach its own timeout. The
        // bubble then sat on "Connecting" until the app was force-quit. Reported by someone whose
        // AirPods reconfigure the input route out from under the recorder, which is one reliable
        // way to get here; the built-in microphone never does it, which is why it only happened
        // with AirPods.
        take.withLockUnchecked { $0.url = nil }
        stopConnectionMonitoring()
        endRecordingActivity()
        updateRecordingState(isRecording: false, isConnecting: false)

        Task { @MainActor in
            SpectrumAnalyzer.shared.stop()
            // Said out loud rather than left to be noticed. A take that captured nothing is
            // otherwise indistinguishable from one the user simply has not finished (#117).
            IndicatorWindowManager.shared.reportRecordingFailure(String(localized: "Recording stopped: the microphone dropped out"))
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Diag.mark("recorder.encodeError \(error?.localizedDescription ?? "unknown")")
    }
}

extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentlyPlayingURL = nil
    }
}
