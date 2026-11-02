import AppKit
import OpenSuperWhisperCore

/// One displayable app/site rule, resolved from the persisted store.
struct AppContextRuleRow: Identifiable {
    /// Storage key: "bundleID" (app-wide) or "bundleID|host" (per-site).
    let id: String
    let bundleID: String
    let host: String?
    let model: DictationModelOption
    let appName: String
    let icon: NSImage?

    static func loadAll() -> [AppContextRuleRow] {
        AppContextModelRules.all().map { key, model -> AppContextRuleRow in
            let (bundleID, host) = parse(key)
            let (name, icon) = appInfo(for: bundleID)
            return AppContextRuleRow(id: key, bundleID: bundleID, host: host,
                                     model: model, appName: name, icon: icon)
        }
        .sorted {
            if $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedSame {
                return ($0.host ?? "") < ($1.host ?? "")
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    static func parse(_ key: String) -> (bundleID: String, host: String?) {
        if let pipe = key.firstIndex(of: "|") {
            return (String(key[..<pipe]), String(key[key.index(after: pipe)...]))
        }
        return (key, nil)
    }

    /// Resolve an installed app's display name + icon; fall back to the bundle id
    /// (with a generic icon) when the app isn't installed any more.
    private static func appInfo(for bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }
}
