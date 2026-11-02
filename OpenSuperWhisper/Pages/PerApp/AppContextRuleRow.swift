import OpenSuperWhisperCore

/// The storage key of a model rule: "bundleID" (app-wide) or "bundleID|host" (per-site).
enum AppContextRuleRow {
    static func parse(_ key: String) -> (bundleID: String, host: String?) {
        if let pipe = key.firstIndex(of: "|") {
            return (String(key[..<pipe]), String(key[key.index(after: pipe)...]))
        }
        return (key, nil)
    }
}
