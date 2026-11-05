import Foundation

/// The per-app on/off switch. One list of bundle identifiers holds the apps switched off, and
/// every per-app lookup (formatting profile, insertion rule, model rule, writing style) asks
/// `isOn` before it answers, so "off" means the same thing everywhere. The rules themselves stay
/// stored: switching an app off never loses what was set for it.
public enum PerAppSwitch {
    /// False when `bundleID` is in `disabled`, whatever the case: bundle identifiers are matched
    /// case-insensitively across the per-app stores. A nil or empty identifier is never off.
    public static func isOn(_ bundleID: String?, disabled: [String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        return !disabled.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// `disabled` with `bundleID` switched on or off, stored lowercased and without duplicates.
    public static func setting(_ bundleID: String, on: Bool, in disabled: [String]) -> [String] {
        let key = bundleID.lowercased()
        var rest = disabled.filter { $0.caseInsensitiveCompare(key) != .orderedSame }
        if !on { rest.append(key) }
        return rest
    }
}
