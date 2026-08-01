import Foundation

/// Frequency layout and scaling for the indicator's spectrum visualiser. Pure maths, kept
/// out of the analyzer so it can be tested without an audio device.
enum SpectrumBands {
    /// Bands drawn on the bubble.
    static let count = 7

    /// Speech energy lives roughly between the male fundamental and the consonant range.
    /// Below 80 Hz is room rumble; above 8 kHz there is little left to show.
    static let lowestHz: Float = 80
    static let highestHz: Float = 8000

    /// Band edges spaced logarithmically, because pitch is perceived that way: a linear
    /// split would give six bands to treble no one notices and one to every vowel.
    static func edges(count: Int = count,
                      lowest: Float = lowestHz,
                      highest: Float = highestHz) -> [Float] {
        guard count > 0, lowest > 0, highest > lowest else { return [] }
        let ratio = highest / lowest
        return (0...count).map { lowest * pow(ratio, Float($0) / Float(count)) }
    }

    /// FFT bin range backing each band, for a given sample rate and transform size.
    /// Bins are clamped inside the spectrum and each band keeps at least one bin, so a
    /// narrow low band on a high sample rate still has something to average.
    static func binRanges(count: Int = count,
                          sampleRate: Float,
                          fftSize: Int) -> [Range<Int>] {
        let bandEdges = edges(count: count)
        guard bandEdges.count == count + 1, sampleRate > 0, fftSize > 1 else { return [] }
        let binCount = fftSize / 2
        let hzPerBin = sampleRate / Float(fftSize)

        return (0..<count).map { index in
            let low = Int(bandEdges[index] / hzPerBin)
            let high = Int(bandEdges[index + 1] / hzPerBin)
            let clampedLow = min(max(low, 0), binCount - 1)
            let clampedHigh = min(max(high, clampedLow + 1), binCount)
            return clampedLow..<clampedHigh
        }
    }

    /// Magnitude to 0...1 for drawing. FFT magnitudes are linear and tiny, so they go
    /// through decibels first; the floor is lower than the level meter's because a single
    /// band holds a fraction of the total energy.
    static let floorDb: Float = -70

    static func normalize(magnitude: Float) -> Float {
        guard magnitude > 0, magnitude.isFinite else { return 0 }
        let db = 20 * log10(magnitude)
        guard db.isFinite else { return 0 }
        let clamped = min(max(db, floorDb), 0)
        return (clamped - floorDb) / -floorDb
    }

    /// Bars fall slower than they rise. Without this the visualiser flickers on every
    /// consonant instead of reading as a voice.
    static func smooth(previous: Float, next: Float, rise: Float = 0.6, fall: Float = 0.18) -> Float {
        let factor = next > previous ? rise : fall
        return previous + (next - previous) * factor
    }
}
