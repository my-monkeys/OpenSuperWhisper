import Foundation

/// Turns `AVAudioRecorder.averagePower` (decibels, -160 to 0) into the 0...1 value the
/// indicator's meter draws.
enum AudioLevel {
    /// Below this, speech is indistinguishable from room noise, so the meter reads empty.
    /// Chosen for close-range dictation: a normal speaking voice into a laptop mic sits
    /// around -30 dB, a quiet room floor around -55 dB.
    static let floorDb: Float = -55

    /// Decibels are logarithmic, so a straight rescale leaves the meter barely moving for
    /// most of the speaking range. The square root spreads normal speech across the bars
    /// instead of bunching it near the bottom.
    static func normalize(power: Float) -> Float {
        guard power.isFinite else { return 0 }
        let clamped = min(max(power, floorDb), 0)
        let linear = (clamped - floorDb) / -floorDb
        return sqrt(linear)
    }

    /// Fill level of bar `index` of `count`, so a meter can light bars progressively:
    /// full below the current level, partial at the boundary, empty above.
    static func barFill(index: Int, count: Int, level: Float) -> Float {
        guard count > 0, index >= 0 else { return 0 }
        let lower = Float(index) / Float(count)
        let upper = Float(index + 1) / Float(count)
        if level >= upper { return 1 }
        if level <= lower { return 0 }
        return (level - lower) / (upper - lower)
    }
}
