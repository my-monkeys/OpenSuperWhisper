import Accelerate
import AVFoundation
import Combine
import Foundation

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

    private let engine = AVAudioEngine()
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

    func start() {
        guard !isRunning, fftSetup != nil else { return }
        guard Self.shouldRun(layout: IndicatorLayout.load(from: AppPreferences.shared.indicatorLayout))
        else { return }

        let input = engine.inputNode

        // `format: nil` rather than a format read a moment ago, and this is the fix rather than a
        // tidy-up. This runs right after `AVAudioRecorder.record()` grabs the device, so the
        // device is often mid-reconfiguration: a format snapshotted here is stale by the time the
        // engine starts, and AVAudioEngine then refuses the tap with a format mismatch. Reported
        // on 0.12.3 as "Failed to create tap due to format mismatch" for 1ch/48kHz/Float32,
        // followed by CoreAudio failing to start the input at all, over and over. Passing nil
        // makes the engine use the bus's own format at the moment the tap is created, so there is
        // no snapshot left to go stale.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let incoming = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            // The buffer knows its own sample rate; nothing read up front can be trusted to still
            // describe it. Sent along so the band edges are derived from the audio that arrived.
            let sampleRate = Float(buffer.format.sampleRate)
            Task { @MainActor in self.consume(incoming, sampleRate: sampleRate) }
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            print("SpectrumAnalyzer: couldn't start the audio engine: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        sampleBuffer.removeAll(keepingCapacity: true)
        cachedRanges = nil
        bands = Array(repeating: 0, count: SpectrumBands.count)
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
        guard sampleRate > 0 else { return }
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
