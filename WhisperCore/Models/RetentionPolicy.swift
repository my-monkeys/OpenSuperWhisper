import Foundation

/// Time unit used by the age-based retention policy.
public enum RetentionUnit: String, CaseIterable, Identifiable {
    case minutes
    case hours
    case days

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minutes: return "Minutes"
        case .hours: return "Hours"
        case .days: return "Days"
        }
    }

    /// Number of seconds in a single unit.
    public var seconds: TimeInterval {
        switch self {
        case .minutes: return 60
        case .hours: return 60 * 60
        case .days: return 60 * 60 * 24
        }
    }
}

/// Snapshot of the user's retention preferences.
///
/// Two independent switches can be active at the same time:
/// - a maximum number of recordings / transcriptions to keep, and
/// - a maximum age, after which recordings are deleted.
public struct RetentionPolicy {
    public var maxCountEnabled: Bool
    public var maxCount: Int
    public var maxAgeEnabled: Bool
    public var maxAgeValue: Int
    public var maxAgeUnit: RetentionUnit

    public init(from prefs: AppPreferences = .shared) {
        self.maxCountEnabled = prefs.retentionMaxCountEnabled
        self.maxCount = prefs.retentionMaxCount
        self.maxAgeEnabled = prefs.retentionMaxAgeEnabled
        self.maxAgeValue = prefs.retentionMaxAgeValue
        self.maxAgeUnit = RetentionUnit(rawValue: prefs.retentionMaxAgeUnit) ?? .days
    }

    /// Whether at least one retention switch is active and meaningful.
    public var isActive: Bool {
        (maxCountEnabled && maxCount > 0) || (maxAgeEnabled && maxAgeValue > 0)
    }

    /// Cutoff date for the age policy. Recordings with a timestamp strictly
    /// before this date are considered expired. `nil` when the age policy is off.
    public func ageCutoffDate(now: Date = Date()) -> Date? {
        guard maxAgeEnabled, maxAgeValue > 0 else { return nil }
        let interval = Double(maxAgeValue) * maxAgeUnit.seconds
        return now.addingTimeInterval(-interval)
    }
}
