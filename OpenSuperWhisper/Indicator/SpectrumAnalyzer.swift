import Accelerate
import AVFoundation
import Combine
import CoreAudio
import Foundation
import os

/// Live spectrum of the microphone, driving the indicator's visualiser.
///
/// Runs its own `AVAudioEngine` tap alongside `AVAudioRecorder`, the same arrangement the
/// Parakeet live transcription already uses: reading the mic in two places is fine, and it
/// keeps analysis away from the file the recorder is writing.
@MainActor
final class SpectrumAnalyzer: ObservableObject {
    static let shared = SpectrumAnalyzer()

    /// Per-band levels, 0...1, oldest-to-highest frequency. All zeros while stopped.
    @Published private(set) var bands: [Float] = Array(repeating: 0, count: SpectrumBands.count)

    #if DEBUG
    /// Stages levels without a microphone, for the indicator probe's screenshots and GIFs.
    func stageBands(_ levels: [Float]) { bands = levels }
    #endif

    /// The engine of each take: a fresh one per take, held by `EngineHost`, nil between takes.
    ///
    /// On macOS the engine's input and output nodes share one HAL I/O unit, and that unit takes
    /// the default input when it is created, the first time `inputNode` is read: the device
    /// itself, or a private aggregate of it and the default output when those differ (see
    /// `devicesBehindInput`). Nothing in AVFAudio promises it follows the default afterwards.
    /// `AudioRecorder` makes the chosen mic the default just before each take, and with one
    /// engine kept for the app's lifetime, a switch from the USB mic to the built-in one gave a
    /// file with the built-in mic at a normal level and a flat bubble. A unit stuck on the first
    /// take's mic fits that, but it is not proven: the default-device aggregate may already be
    /// rebuilt when the defaults change, in which case the cause is the aggregate or its channel
    /// layout. `spectrum.input` in the diagnostic log names the devices the tap is on next to
    /// the default, so a report of a flat bubble settles which. A coreaudiod restart would leave
    /// a kept engine on a device that no longer exists at all.
    ///
    /// A new engine reads the default the recorder has just set, the same rule
    /// `AVAudioRecorder` follows, so both open the same device without passing it around.
    /// Pointing a kept engine at the recorder's device instead
    /// (`kAudioOutputUnitProperty_CurrentDevice` on its unit) also works on paper, but switching
    /// a unit's device has been reported to leave the input node on a 0 Hz / 0 channel format,
    /// the same kind of stale format #107 was about. Building and releasing the unit (and its
    /// aggregate) is timed as `spectrum.engine` and `spectrum.release`. It runs on the engine
    /// queue, not the main actor: with a Bluetooth headset the build alone took 288 to 583 ms
    /// (#340), long enough that the indicator, shown by the same thread, could not draw. If it is
    /// still too slow, keep the engine across takes while it still sits on the default input.
    private let engineHost = EngineHost()
    /// Which take the engine queue is working for. Bumped by `start()` and `stop()` on the main
    /// actor, read by the engine queue to drop a build that nobody wants any more. A lock rather
    /// than main-actor state because the queue cannot read that without waiting for main.
    private nonisolated let latestGeneration = OSAllocatedUnfairLock(initialState: 0)
    /// Between `start()` and `stop()`, including while the engine is still being built.
    private var takeActive = false
    /// True once the engine is up and its tap is feeding `consume`.
    private var isRunning = false

    private let fftSize = 1024
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var window: [Float]
    /// Ring of the newest samples, so a short tap buffer still produces a full transform.
    private var sampleBuffer: [Float] = []

    private init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Whether a second microphone tap is worth opening at all.
    ///
    /// It only feeds the visualiser, so with no visualiser on the bubble it is a second claim on
    /// the input device for nothing. That claim is not free: it lands immediately after
    /// `AVAudioRecorder.record()` has taken the device, which is exactly when a route or format
    /// reconfiguration is in flight (#107 follow-up).
    nonisolated static func shouldRun(layout: IndicatorLayout) -> Bool {
        layout.contains(.waveform)
    }

    /// Whether the build that began at `build` is still the take the analyzer is on. Stale after
    /// a `stop()`, and after the stop-and-start of the next take.
    nonisolated static func isCurrent(build: Int, latest: Int) -> Bool {
        build == latest
    }

    func start() {
        guard !takeActive, fftSetup != nil else { return }
        guard Self.shouldRun(layout: IndicatorLayout.load(from: AppPreferences.shared.indicatorLayout))
        else { return }

        takeActive = true
        let take = latestGeneration.withLock { generation -> Int in
            generation += 1
            return generation
        }
        let host = engineHost
        let latest = latestGeneration
        host.queue.async { [weak self] in
            guard Self.isCurrent(build: take, latest: latest.withLock { $0 }) else { return }
            let started = host.build(
                onBuffer: { samples, sampleRate in
                    Task { @MainActor in self?.consume(samples, sampleRate: sampleRate) }
                },
                onConfigurationChange: { Task { @MainActor in self?.configurationChanged(during: take) } })
            Task { @MainActor in self?.buildFinished(started, for: take) }
        }
    }

    /// A `stop()` that landed during the build has already queued the teardown behind it on the
    /// engine queue, so a stale result needs nothing more than being ignored here.
    private func buildFinished(_ started: Bool, for take: Int) {
        guard started, Self.isCurrent(build: take, latest: latestGeneration.withLock { $0 }) else { return }
        isRunning = true
    }

    /// A change to the input device's rate or channel count stops the engine on its own (see
    /// `AVAudioEngineConfigurationChangeNotification`), which used to leave a tap that would never
    /// fire again and an `isRunning` that said otherwise. Stopping properly settles the bands at
    /// zero and drops the dead engine; the next take builds a new one.
    ///
    /// Not restarted in place: a change mid-take means the device is being reconfigured under the
    /// recorder, the moment #107 showed a second start failing over and over, and a flat bubble
    /// is the cheaper failure. The notification arrives on an internal queue where releasing the
    /// engine can deadlock, so the stop hops to the main actor, which hands it to the engine queue.
    private func configurationChanged(during take: Int) {
        guard Self.isCurrent(build: take, latest: latestGeneration.withLock { $0 }) else { return }
        Diag.mark("spectrum.configurationChange; visualiser off for the rest of this take")
        stop()
    }

    /// The devices the engine's input reads from. When the default input and output are
    /// different devices, a fresh engine sits on a private aggregate of the two rather than on
    /// the input itself: on a Mac recording from the built-in mic (98) and playing to Bluetooth
    /// speakers, the unit reported device 155, which no other process can see and which holds the
    /// mic. Its members are listed instead, so the input can be compared with the default. Reads
    /// properties only; nothing is opened.
    nonisolated static func devicesBehindInput(of engine: AVAudioEngine) -> [AudioDeviceID] {
        let device = engine.inputNode.auAudioUnit.deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return [device] }
        var members = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &members) == noErr
        else { return [device] }
        return members
    }

    func stop() {
        guard takeActive else { return }
        takeActive = false
        isRunning = false
        latestGeneration.withLock { $0 += 1 }
        sampleBuffer.removeAll(keepingCapacity: true)
        cachedRanges = nil
        bands = Array(repeating: 0, count: SpectrumBands.count)
        let host = engineHost
        host.queue.async { Diag.measure("spectrum.release") { host.teardown() } }
    }

    /// Band edges for one sample rate, kept so they are not recomputed for every buffer. Keyed by
    /// the rate rather than computed once at start, because the device can change rate underneath
    /// a running tap.
    private var cachedRanges: (sampleRate: Float, ranges: [Range<Int>])?

    private func binRanges(for sampleRate: Float) -> [Range<Int>] {
        if let cachedRanges, cachedRanges.sampleRate == sampleRate { return cachedRanges.ranges }
        let ranges = SpectrumBands.binRanges(sampleRate: sampleRate, fftSize: fftSize)
        cachedRanges = (sampleRate, ranges)
        return ranges
    }

    private func consume(_ samples: [Float], sampleRate: Float) {
        // A buffer already in flight when the take stopped must not lift the bands back up.
        guard isRunning, sampleRate > 0 else { return }
        let ranges = binRanges(for: sampleRate)
        sampleBuffer.append(contentsOf: samples)
        guard sampleBuffer.count >= fftSize else { return }
        // Keep only the newest window; older audio has already been drawn.
        sampleBuffer.removeFirst(sampleBuffer.count - fftSize)

        let magnitudes = transform(sampleBuffer)
        guard !magnitudes.isEmpty else { return }

        bands = ranges.enumerated().map { index, range in
            let slice = magnitudes[range.clamped(to: 0..<magnitudes.count)]
            guard !slice.isEmpty else { return 0 }
            let peak = slice.max() ?? 0
            let target = SpectrumBands.normalize(magnitude: peak)
            let previous = index < bands.count ? bands[index] : 0
            return SpectrumBands.smooth(previous: previous, next: target)
        }
    }

    /// Windowed real FFT of one frame, returning bin magnitudes.
    private func transform(_ frame: [Float]) -> [Float] {
        guard let fftSetup, frame.count == fftSize else { return [] }
        let half = fftSize / 2

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowPtr in
                    windowPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // vDSP's real FFT returns twice the true amplitude, and the window removed energy.
        var scale = Float(1) / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))
        return magnitudes
    }
}

/// The engine of the take in progress and everything done to it, confined to `queue`.
///
/// Creating, starting and releasing an `AVAudioEngine` blocks on CoreAudio for as long as the
/// device takes to answer, so none of it may run where the indicator is drawn.
private final class EngineHost: @unchecked Sendable {
    let queue = DispatchQueue(label: "fr.my-monkey.opensuperwhisper.spectrum.engine", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    /// Builds and starts the engine with a tap that reports each buffer; false when the visualiser
    /// stays off for this take. Call on `queue`.
    func build(onBuffer: @escaping @Sendable ([Float], Float) -> Void,
               onConfigurationChange: @escaping @Sendable () -> Void) -> Bool {
        // Reading `inputNode` is what creates the I/O unit, and with it any default-device
        // aggregate, so it is inside the measurement: that is the part that can block.
        let engine = Diag.measure("spectrum.engine") { () -> AVAudioEngine in
            let engine = AVAudioEngine()
            _ = engine.inputNode
            return engine
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Diag.mark("spectrum.input=\(SpectrumAnalyzer.devicesBehindInput(of: engine)) "
            + "default=\(MicrophoneService.shared.getCurrentSystemDefaultInputDevice().map(String.init) ?? "none") "
            + "format=\(format.channelCount)ch/\(Int(format.sampleRate))Hz")

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

        do {
            try ObjCExceptionError.catching { engine.prepare() }
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            print("SpectrumAnalyzer: couldn't start the audio engine: \(error)")
            return false
        }
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in onConfigurationChange() }
        return true
    }

    /// Call on `queue`. Through the property rather than a local binding, so the last reference
    /// goes inside the caller's measurement and the unit's teardown is counted in it.
    func teardown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
