import Foundation
import OpenSuperWhisperCore

/// Per-app and per-site values kept in one dictionary: the key is the lowercased bundle id for an
/// app and "<bundle id>|<host>" for one site of a browser (writing styles, AI cleanup).
enum PerAppOverride {
    static func key(bundleID: String, host: String?) -> String {
        let app = bundleID.lowercased()
        guard let host, !host.isEmpty else { return app }
        return "\(app)|\(host.lowercased())"
    }

    /// The site's value, else the app's, else nil, which means "follow the global setting". nil
    /// too while the app is switched off: its site values stop applying with the rest of it.
    static func value<Value>(in values: [String: Value], bundleID: String?, host: String?,
                             disabled: [String]) -> Value? {
        guard let bundleID, !bundleID.isEmpty, PerAppSwitch.isOn(bundleID, disabled: disabled) else { return nil }
        if let host, let site = values[key(bundleID: bundleID, host: host)] { return site }
        return values[key(bundleID: bundleID, host: nil)]
    }
}
