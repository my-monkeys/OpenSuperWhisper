import AVFoundation
import Foundation
import SwiftUI
import AppKit
import CoreAudio

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentlyPlayingURL: URL?
    @Published var canRecord = false
    @Published var isConnecting = false
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var notificationSound: NSSound?
    private let temporaryDirectory: URL
    private var currentRecordingURL: URL?
    private var notificationObserver: Any?
    private var microphoneChangeObserver: Any?
    private var connectionCheckTimer: DispatchSourceTimer?
    private var recordingDeviceID: AudioDeviceID?
    // Keeps audio hardware warm so the first word is never cut off
    private var primedRecorder: AVAudioRecorder?

    /// Holds App Nap off for as long as a recording is running. Nil when nothing is recording.
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
    private var recordingActivity: NSObjectProtocol?

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
        primeAudioHardware()

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

    /// Pre-warms the audio hardware by creating a prepared (but not recording) AVAudioRecorder.
    /// Keeping `primedRecorder` alive holds the audio engine in an initialized state,
    /// eliminating the cold-start delay when the user triggers the first real recording.
    private func primeAudioHardware() {
        let primedURL = temporaryDirectory.appendingPathComponent("primed.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]
        primedRecorder = try? AVAudioRecorder(url: primedURL, settings: settings)
        primedRecorder?.prepareToRecord()
    }
    
    private func createTemporaryDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create temporary recordings directory: \(error)")
        }
    }
    
    /// The short chime used to confirm a recording state change. Internal rather than private so
    /// the Space latch can reuse it — same class of feedback, same preference.
    func playNotificationSound() {
        // Try to play using NSSound first
        guard let soundURL = Bundle.main.url(forResource: "notification", withExtension: "mp3") else {
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
    /// See `recordingActivity`. Ending any assertion already held keeps them from stacking: a
    /// start that never saw a matching stop would otherwise leak one and hold App Nap off for good.
    /// Internal rather than private so a test can check the pair stays balanced.
    func beginRecordingActivity() {
        endRecordingActivity()
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Recording audio for dictation")
    }

    /// Releases the assertion. Safe to call when none is held, which is what makes it usable both
    /// on every exit path and as the guard against stacking in `beginRecordingActivity`.
    func endRecordingActivity() {
        guard let activity = recordingActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        recordingActivity = nil
    }

    /// Whether an assertion is currently held. Exists so a test can check that starting and
    /// stopping a recording leaves none behind.
    var isHoldingRecordingActivity: Bool { recordingActivity != nil }

    func startRecording() {
        Diag.mark("recorder.startRecording (canRecord=\(canRecord))")
        guard canRecord else {
            print("Cannot start recording - no audio input available")
            return
        }

        if isRecording || isConnecting {
            print("stop recording while recording")
            _ = stopRecording()
        }

        // Before any of the audio setup, so the connection wait and the state updates that follow
        // are already protected from being throttled. (#98)
        beginRecordingActivity()

        if AppPreferences.shared.pauseMediaOnRecord {
            MediaPlaybackController.shared.pauseMedia()
        }
        if AppPreferences.shared.reduceVolumeOnRecord {
            SystemVolumeController.shared.duck(to: Float32(AppPreferences.shared.reduceVolumeLevel))
        }

        if AppPreferences.shared.playSoundOnRecordStart {
            playNotificationSound()
        }

        // A UUID suffix keeps each recording's temp file unique. Without it, two recordings
        // started in the same wall-clock second share a path — and starting the next recording
        // would truncate the previous clip's file while the background pipeline is still reading
        // it to transcribe. (parallel-recording)
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "rec-\(timestamp)-\(UUID().uuidString.prefix(8)).wav"
        let fileURL = temporaryDirectory.appendingPathComponent(filename)
        currentRecordingURL = fileURL

        print("start record file to \(fileURL)")

        #if os(macOS)
        if let activeMic = MicrophoneService.shared.getActiveMicrophone() {
            Diag.measure("setAsSystemDefaultInput") {
                _ = MicrophoneService.shared.setAsSystemDefaultInput(activeMic)
            }
            print("Set system default input to: \(activeMic.displayName)")

            if let deviceID = MicrophoneService.shared.getCoreAudioDeviceID(for: activeMic) {
                recordingDeviceID = deviceID
            }
        }
        #endif

        let requiresConnection = Diag.measure("isActiveMicrophoneRequiresConnection") {
            MicrophoneService.shared.isActiveMicrophoneRequiresConnection()
        }
        // Which device a take ran on and whether it has to connect first: the two facts that pick
        // the start path, and the first two worth knowing from a report of a take going wrong.
        Diag.mark("recorder.device=\(MicrophoneService.shared.getActiveMicrophone()?.displayName ?? "none") "
            + "requiresConnection=\(requiresConnection)")
        updateRecordingState(isRecording: false, isConnecting: requiresConnection)
        startRecordingWithRecorder(fileURL: fileURL, monitorConnection: requiresConnection)
    }
    
    private func startRecordingWithRecorder(fileURL: URL, monitorConnection: Bool) {
        var channelCount = 1
        if let activeMic = MicrophoneService.shared.getActiveMicrophone() {
            channelCount = MicrophoneService.shared.getInputChannelCount(for: activeMic)
            print("Recording with \(channelCount) input channel(s) from \(activeMic.displayName)")
        }
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]
        
        do {
            primedRecorder = nil  // release primed recorder just before starting; hardware stays warm
            try Diag.measure("AVAudioRecorder init+record") {
                audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
                audioRecorder?.delegate = self
                audioRecorder?.isMeteringEnabled = monitorConnection
                audioRecorder?.record()
            }
            Task { @MainActor in SpectrumAnalyzer.shared.start() }
            if monitorConnection {
                startConnectionMonitoring()
            } else {
                updateRecordingState(isRecording: true, isConnecting: false)
            }
            print("Recording started successfully")
        } catch {
            print("Failed to start recording: \(error)")
            currentRecordingURL = nil
            // No recording to protect, and nothing will call `stopRecording` for a start that
            // never happened — so release the assertion here or it is held for ever.
            endRecordingActivity()
            updateRecordingState(isRecording: false, isConnecting: false)
        }
    }
    
    func stopRecording() -> URL? {
        // Runs on the main thread (IndicatorViewModel is @MainActor). AudioQueueStop waits for the
        // queue to drain, so an input device pulled out from under it could stall the app here —
        // timed so a `▶` with no `◀` would name it rather than leaving a silent freeze.
        Diag.measure("AVAudioRecorder.stop") { audioRecorder?.stop() }
        endRecordingActivity()

        updateRecordingState(isRecording: false, isConnecting: false)
        Task { @MainActor in SpectrumAnalyzer.shared.stop() }
        stopConnectionMonitoring()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.primeAudioHardware()  // re-prime so the next recording starts instantly too
        }

        if AppPreferences.shared.pauseMediaOnRecord {
            MediaPlaybackController.shared.resumeMedia()
        }
        if AppPreferences.shared.reduceVolumeOnRecord {
            SystemVolumeController.shared.restore()
        }

        if let url = currentRecordingURL,
           let duration = try? AVAudioPlayer(contentsOf: url).duration,
           duration < 1.0
        {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
            return nil
        }

        let url = currentRecordingURL
        currentRecordingURL = nil
        return url
    }

    func cancelRecording() {
        // Same blocking AudioQueueStop as `stopRecording`, timed for the same reason.
        Diag.measure("AVAudioRecorder.stop (cancel)") { audioRecorder?.stop() }
        endRecordingActivity()
        updateRecordingState(isRecording: false, isConnecting: false)
        Task { @MainActor in SpectrumAnalyzer.shared.stop() }
        stopConnectionMonitoring()

        if AppPreferences.shared.pauseMediaOnRecord {
            MediaPlaybackController.shared.resumeMedia()
        }
        if AppPreferences.shared.reduceVolumeOnRecord {
            SystemVolumeController.shared.restore()
        }
        
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentRecordingURL = nil
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

    private func startConnectionMonitoring() {
        stopConnectionMonitoring()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        let initialFileSize: Int64 = 4096
        let startedAt = Date()
        var growthCount = 0

        timer.setEventHandler { [weak self] in
            guard let self = self, let _ = self.audioRecorder, let url = self.currentRecordingURL else { return }

            let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let totalGrowth = currentFileSize - initialFileSize

            if totalGrowth > 8000 {
                growthCount += 1
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            guard Self.shouldGoLive(growthObservations: growthCount, elapsed: elapsed) else { return }

            if growthCount < 2 {
                Diag.mark("recorder.connectionWait timed out after \(Int(elapsed * 1000))ms "
                    + "with \(totalGrowth) bytes written; going live anyway")
            }
            self.stopConnectionMonitoring()
            self.updateRecordingState(isRecording: true, isConnecting: false)
        }
        connectionCheckTimer = timer
        timer.resume()
    }

    private func stopConnectionMonitoring() {
        connectionCheckTimer?.cancel()
        connectionCheckTimer = nil
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Only the failure is worth a line: it clears `currentRecordingURL`, which is also what the
        // connection monitor guards on, so a take can end here and leave the wait with nothing to
        // measure.
        if !flag {
            Diag.mark("recorder.didFinishRecording failed — clip discarded")
            currentRecordingURL = nil
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
