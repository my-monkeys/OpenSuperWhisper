import Dispatch
import Foundation

/// The one clock every duration in this app is measured with.
public enum UptimeClock {
    /// The house monotonic clock — the same expression `Diag.measure` already uses.
    /// Excludes time asleep; correct here, because a sleeping Mac is not transcribing.
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Milliseconds from `start` to `end`, wrapper-safe. Never negative.
    ///
    /// A wall clock (`Date`) is never used for a duration: an NTP correction or a manual
    /// change would corrupt it.
    public static func milliseconds(from start: UInt64, to end: UInt64 = UptimeClock.now()) -> Int {
        Int(clamping: (end &- start) / 1_000_000)
    }
}
