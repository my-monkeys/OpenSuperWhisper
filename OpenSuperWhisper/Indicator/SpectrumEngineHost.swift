import AVFoundation
import CoreAudio
import Foundation
import os

/// The default input and output at one moment, which is what a new engine's I/O unit opens.
struct SpectrumDefaultDevices: Equatable, Sendable {
    var input: AudioDeviceID
    var output: AudioDeviceID

    static func current() -> SpectrumDefaultDevices {
        SpectrumDefaultDevices(input: defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
                               output: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioDeviceID(kAudioObjectUnknown)
    }
}

enum SpectrumEngineReuse {
    /// Why the kept engine cannot serve the next take, or nil when it can.
    ///
    /// Up to 0.12.x one engine served the app's whole life, and after a switch from a USB mic to
    /// the built-in one the bubble stayed flat while the file had the built-in mic at a normal
    /// level: a unit still on the first mic fits that. `AudioRecorder` makes the take's mic the
    /// default just before the take, so the defaults are compared with the ones the engine was
    /// built on. The devices actually behind its input are compared with the default input too,
    /// which also catches a unit left on a device or aggregate that no longer exists, after a
    /// coreaudiod restart for instance, while the defaults look unchanged.
    static func rebuildReason(builtFor: SpectrumDefaultDevices, now: SpectrumDefaultDevices,
                              devicesBehindInput: [AudioDeviceID], configurationChanged: Bool) -> String? {
        if configurationChanged { return "the engine reported a configuration change" }
        if now.input != builtFor.input { return "default input \(builtFor.input) is now \(now.input)" }
        if now.output != builtFor.output { return "default output \(builtFor.output) is now \(now.output)" }
        if !devicesBehindInput.contains(now.input) {
            return "input on \(devicesBehindInput) while the default is \(now.input)"
        }
        return nil
    }
}

/// Stopped engines waiting for Core Audio to report that their device no longer runs.
///
/// Releasing an engine disposes its I/O unit. Crash reports from 0.15.2 to 0.15.5 show the
/// visualiser's engine being released on its queue right after `stop()` while the unit's I/O
/// thread was still calling into it, and that thread then jumped to a null address inside
/// CoreAudio.component. `stop()` returning does not mean that thread is done, so the release
/// waits for the device to say it is no longer running in this process. That is the device's
/// own state rather than a delay, and it holds whatever the device takes to stop.
struct DeferredReleases<Item: AnyObject> {
    struct Entry {
        let item: Item
        let device: AudioDeviceID
        let retiredAt: UInt64
        var listener: AudioObjectPropertyListenerBlock?
    }

    private(set) var entries: [Entry] = []

    mutating func add(_ entry: Entry) {
        entries.append(entry)
    }

    /// Removes and returns the entries whose device has stopped, reading each device once.
    mutating func takeStopped(isRunning: (AudioDeviceID) -> Bool) -> [Entry] {
        var running: [AudioDeviceID: Bool] = [:]
        var stopped: [Entry] = []
        var waiting: [Entry] = []
        for entry in entries {
            let deviceRuns = running[entry.device] ?? isRunning(entry.device)
            running[entry.device] = deviceRuns
            if deviceRuns { waiting.append(entry) } else { stopped.append(entry) }
        }
        entries = waiting
        return stopped
    }
}

/// The visualiser's engine and everything done to it, confined to `queue`.
///
/// One engine serves take after take while it still sits on the default devices, and is replaced
/// when they change (see `SpectrumEngineReuse`). Creating, starting and releasing an
/// `AVAudioEngine` blocks on CoreAudio for as long as the device takes to answer, so none of it
/// may run where the indicator is drawn.
final class SpectrumEngineHost: @unchecked Sendable {
    let queue = DispatchQueue(label: "fr.my-monkey.opensuperwhisper.spectrum.engine", qos: .userInitiated)
    /// Where Core Audio reports a retired engine's device stopping. Not `queue`: removing a
    /// listener waits for its calls in flight, and a call queued on `queue` behind the removal
    /// would never get to run.
    private let deviceEvents = DispatchQueue(label: "fr.my-monkey.opensuperwhisper.spectrum.device-state")

    /// How long a kept engine has to deliver its first buffer before it is presumed deaf and
    /// replaced. Generous, because a Bluetooth mic can take a second or two to switch profile.
    static let firstBufferDeadline: DispatchTimeInterval = .seconds(3)

    private static let isRunningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunning,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private var engine: AVAudioEngine?
    private var builtFor = SpectrumDefaultDevices(input: AudioDeviceID(kAudioObjectUnknown),
                                                  output: AudioDeviceID(kAudioObjectUnknown))
    /// Set by `AVAudioEngineConfigurationChange`: the engine stopped itself and is not reused.
    private var configurationChanged = false
    /// Tells a configuration change of a replaced engine from one of the current engine.
    private var engineGeneration = 0
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false
    /// The handler of the take in progress; nil between takes.
    private var onConfigurationChange: (@Sendable () -> Void)?
    private var retired = DeferredReleases<AVAudioEngine>()

    /// Starts the visualiser for a take, on the kept engine when it still fits and on a new one
    /// otherwise. False when the visualiser stays off for this take. Call on `queue`.
    func startTake(onBuffer: @escaping @Sendable ([Float], Float) -> Void,
                   onConfigurationChange: @escaping @Sendable () -> Void,
                   isCurrent: @escaping @Sendable () -> Bool) -> Bool {
        releaseStoppedEngines()
        self.onConfigurationChange = onConfigurationChange
        let defaults = SpectrumDefaultDevices.current()
        let firstBuffer = OSAllocatedUnfairLock(initialState: false)

        if let engine {
            let behindInput = SpectrumAnalyzer.devicesBehindInput(of: engine)
            if let reason = SpectrumEngineReuse.rebuildReason(
                builtFor: builtFor, now: defaults,
                devicesBehindInput: behindInput, configurationChanged: configurationChanged) {
                Diag.mark("spectrum.rebuild: \(reason)")
                retireEngine()
            } else if startTap(on: engine, onBuffer: onBuffer, firstBuffer: firstBuffer) {
                Diag.mark("spectrum.reuse input=\(behindInput) default=\(defaults.input)")
                watchFirstBuffer(firstBuffer, onBuffer: onBuffer, isCurrent: isCurrent)
                return true
            } else {
                Diag.mark("spectrum.reuse refused to start; building a new engine")
                retireEngine()
            }
        }

        let engine = buildEngine(for: defaults)
        guard startTap(on: engine, onBuffer: onBuffer, firstBuffer: firstBuffer) else {
            retireEngine()
            return false
        }
        return true
    }

    /// Ends the take's tap and stops the engine, which stays for the next take. Call on `queue`.
    func endTake() {
        onConfigurationChange = nil
        if let engine { Diag.measure("spectrum.stop") { stopTap(of: engine) } }
        releaseStoppedEngines()
    }

    // MARK: Building and starting

    private func buildEngine(for defaults: SpectrumDefaultDevices) -> AVAudioEngine {
        // Reading `inputNode` is what creates the I/O unit, and with it any default-device
        // aggregate, so it is inside the measurement: that is the part that can block.
        let engine = Diag.measure("spectrum.engine") { () -> AVAudioEngine in
            let engine = AVAudioEngine()
            _ = engine.inputNode
            return engine
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        Diag.mark("spectrum.input=\(SpectrumAnalyzer.devicesBehindInput(of: engine)) "
            + "default=\(defaults.input) format=\(format.channelCount)ch/\(Int(format.sampleRate))Hz")

        engineGeneration += 1
        let generation = engineGeneration
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Posted on an internal queue where touching the engine can deadlock.
            self?.queue.async { self?.configurationDidChange(generation) }
        }
        self.engine = engine
        builtFor = defaults
        configurationChanged = false
        return engine
    }

    /// Installs the take's tap and starts the engine. On failure the tap is gone again.
    private func startTap(on engine: AVAudioEngine,
                          onBuffer: @escaping @Sendable ([Float], Float) -> Void,
                          firstBuffer: OSAllocatedUnfairLock<Bool>) -> Bool {
        let input = engine.inputNode
        // `format: nil` rather than a format read a moment ago, and this is the fix rather than a
        // tidy-up. This runs right after `AVAudioRecorder.record()` grabs the device, so the
        // device is often mid-reconfiguration: a format snapshotted here is stale by the time the
        // engine starts, and AVAudioEngine then refuses the tap with a format mismatch. Reported
        // on 0.12.3 as "Failed to create tap due to format mismatch" for 1ch/48kHz/Float32,
        // followed by CoreAudio failing to start the input at all, over and over. Passing nil
        // makes the engine use the bus's own format at the moment the tap is created, so there is
        // no snapshot left to go stale.
        //
        // `format: nil` narrows the window but does not close it: a device caught mid-change can
        // still make `installTap` raise, and an NSException here is far worse than no visualiser
        // (see `OSWCatchException`). So it is caught and the bubble simply stays flat.
        do {
            try ObjCExceptionError.catching {
                input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                    firstBuffer.withLock { $0 = true }
                    guard let channel = buffer.floatChannelData?[0] else { return }
                    let incoming = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                    // The buffer knows its own sample rate; nothing read up front can be trusted to
                    // still describe it. Sent along so the band edges are derived from the audio that
                    // arrived.
                    onBuffer(incoming, Float(buffer.format.sampleRate))
                }
            }
        } catch {
            Diag.mark("spectrum.installTap raised \(error.localizedDescription); visualiser off for this take")
            return false
        }
        tapInstalled = true

        do {
            try ObjCExceptionError.catching { engine.prepare() }
            try engine.start()
        } catch {
            stopTap(of: engine)
            print("SpectrumAnalyzer: couldn't start the audio engine: \(error)")
            return false
        }
        return true
    }

    private func stopTap(of engine: AVAudioEngine) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    /// A kept engine that starts but never delivers is replaced within the take. A unit gone deaf
    /// in a way the device checks cannot see then costs a few seconds of flat bubble, not every
    /// take after it.
    private func watchFirstBuffer(_ firstBuffer: OSAllocatedUnfairLock<Bool>,
                                  onBuffer: @escaping @Sendable ([Float], Float) -> Void,
                                  isCurrent: @escaping @Sendable () -> Bool) {
        queue.asyncAfter(deadline: .now() + Self.firstBufferDeadline) { [self] in
            guard isCurrent(), !firstBuffer.withLock({ $0 }) else { return }
            Diag.mark("spectrum.reuse delivered nothing; building a new engine")
            retireEngine()
            let engine = buildEngine(for: SpectrumDefaultDevices.current())
            if !startTap(on: engine, onBuffer: onBuffer, firstBuffer: firstBuffer) { retireEngine() }
        }
    }

    private func configurationDidChange(_ generation: Int) {
        guard generation == engineGeneration else { return }
        configurationChanged = true
        onConfigurationChange?()
    }

    // MARK: Retiring

    /// Stops the current engine and hands it over to be released once its device has stopped.
    private func retireEngine() {
        guard let engine else { return }
        stopTap(of: engine)
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        self.engine = nil
        engineGeneration += 1

        var entry = DeferredReleases<AVAudioEngine>.Entry(
            item: engine, device: engine.inputNode.auAudioUnit.deviceID,
            retiredAt: DispatchTime.now().uptimeNanoseconds)
        // Listening before the first read, so a stop that lands in between is still heard.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.releaseStoppedEngines() }
        }
        var address = Self.isRunningAddress
        if AudioObjectAddPropertyListenerBlock(entry.device, &address, deviceEvents, listener) == noErr {
            entry.listener = listener
        }
        retired.add(entry)
        releaseStoppedEngines()
    }

    /// Also run at every take's start and end, which covers a listener that could not be added.
    private func releaseStoppedEngines() {
        var stopped = retired.takeStopped(isRunning: Self.ioIsRunning(on:))
        guard !stopped.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        for entry in stopped {
            if let listener = entry.listener {
                var address = Self.isRunningAddress
                AudioObjectRemovePropertyListenerBlock(entry.device, &address, deviceEvents, listener)
            }
            Diag.mark("spectrum.release: device \(entry.device) stopped "
                + "\((now &- entry.retiredAt) / 1_000_000) ms after the engine was retired")
        }
        // The last references go inside the measurement, so the units' teardown is counted in it.
        Diag.measure("spectrum.release") { stopped.removeAll() }
    }

    /// Whether the device's I/O runs anywhere in this process, the recorder's included.
    static func ioIsRunning(on device: AudioDeviceID) -> Bool {
        var address = isRunningAddress
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        // A device that cannot answer is gone, and no I/O runs on a device that is gone.
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
