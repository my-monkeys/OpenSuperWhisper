import Dispatch
import Foundation

/// Where a dictation's wall-clock time went (#262), in integer milliseconds.
///
/// A stage that did not run is `nil`; a stage that ran instantly is `0`. Those are different
/// facts and the whole point of the type: nil means "no pass was due / no insertion happened",
/// 0 means "it happened and cost nothing measurable".
///
/// The blob is versioned and decoded failably: a value this build cannot read renders as
/// "not measured", never as a partially-read measurement.
public struct DictationTiming: Codable, Equatable, Sendable {
    /// Bumped only when a field changes meaning. See `decode(_:)`.
    public static let currentVersion = 1

    public var version: Int = DictationTiming.currentVersion

    /// Stop press → clip handed to `DictationPipeline.enqueue`.
    public var finalizeMs: Int?
    /// `enqueue` → `process(_:)` entry, i.e. waiting behind earlier dictations.
    public var queueWaitMs: Int?
    /// Inside `transcribeAudio`: waiting on the process-wide engine gate.
    public var engineWaitMs: Int?
    /// Inside `transcribeAudio`: `ensureEngineLoaded`. 0 when the engine was already up.
    public var engineLoadMs: Int?
    /// The whole `retryingOnce` call, so it is the wall time the user waited.
    public var transcribeMs: Int?
    /// 1 normally, 2 when the retry fired. Nil when no engine run happened at all.
    public var transcribeAttempts: Int?
    /// The LLM pass. Nil when no pass was due (or, on a failure, it never ran).
    public var cleanupMs: Int?
    /// Focus return + insertion. Nil when nothing was inserted.
    public var insertMs: Int?
    /// Stop press → the dictation's terminal point (insertion, agent hand-off, recovery
    /// hand-off, or the failure being surfaced).
    public var totalMs: Int?
    /// The Mac at the stop instant (#262: "the Mac's load at that moment").
    public var machine: MachineState?

    public init() {}

    /// True when no stage was stamped. `encoded` returns nil for an empty value so the column
    /// stays NULL rather than holding `{"version":1}`.
    public var isEmpty: Bool {
        finalizeMs == nil && queueWaitMs == nil && engineWaitMs == nil && engineLoadMs == nil
            && transcribeMs == nil && transcribeAttempts == nil && cleanupMs == nil
            && insertMs == nil && totalMs == nil && machine == nil
    }

    /// JSON for the column; nil when `isEmpty` or encoding fails.
    public var encoded: String? {
        guard !isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // stable bytes: diffable and test-friendly
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Failable by contract. Returns nil for nil input, malformed JSON, or a version newer
    /// than this build. Never throws: a throwing decode inside `Recording`'s `FetchableRecord`
    /// would let one corrupt row take the whole Home list down.
    public static func decode(_ json: String?) -> DictationTiming? {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(DictationTiming.self, from: data),
              decoded.version <= DictationTiming.currentVersion
        else { return nil }
        return decoded
    }
}

/// The Mac at the stop instant. Captured in the APP target (see `MachineState+Capture.swift`),
/// carried here as plain values so the core type stays platform-neutral and iOS-safe.
public struct MachineState: Codable, Equatable, Sendable {
    /// "nominal" | "fair" | "serious" | "critical".
    public var thermalState: String
    public var lowPowerMode: Bool
    /// One-minute load average. Nil when `getloadavg` failed or returned short.
    public var loadAverage1m: Double?

    public init(thermalState: String, lowPowerMode: Bool, loadAverage1m: Double?) {
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.loadAverage1m = loadAverage1m
    }
}
