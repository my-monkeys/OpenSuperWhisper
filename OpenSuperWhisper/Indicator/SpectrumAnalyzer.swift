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

    func start() {
        guard !isRunning, fftSetup != nil else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let sampleRate = Float(format.sampleRate)
        let ranges = SpectrumBands.binRanges(sampleRate: sampleRate, fftSize: fftSize)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let incoming = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            Task { @MainActor in self.consume(incoming, ranges: ranges) }
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
        bands = Array(repeating: 0, count: SpectrumBands.count)
    }

    private func consume(_ samples: [Float], ranges: [Range<Int>]) {
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
