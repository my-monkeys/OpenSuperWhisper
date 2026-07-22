import AppKit
import Foundation

/// A user-facing application discovered on disk, used by the app-aware formatting picker so the
/// user chooses an app from a list instead of typing its bundle identifier.
struct InstalledApp: Identifiable, Hashable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
    let url: URL
}

enum InstalledApps {
    /// Standard locations where `.app` bundles live. Covers the vast majority of apps; anything
    /// outside these can still be added via the picker's "Browse…" (NSOpenPanel) escape hatch.
    private static let searchRoots: [URL] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ].map { URL(fileURLWithPath: $0) }

    /// All installed apps, de-duplicated by bundle id and sorted by display name.
    static func all() -> [InstalledApp] {
        var seen = Set<String>()
        var result: [InstalledApp] = []
        for root in searchRoots {
            // Path-based enumeration on purpose: the URL-based `contentsOfDirectory(at:)` silently
            // drops symlinks into the macOS Cryptex (e.g. /Applications/Safari.app →
            // ../System/Cryptexes/…), which would omit Safari and other sealed system apps. The
            // path variant lists the symlink; `Bundle(url:)` then resolves it to the real bundle.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names where name.hasSuffix(".app") {
                let url = root.appendingPathComponent(name)
                guard let app = app(at: url), !seen.contains(app.bundleIdentifier) else { continue }
                seen.insert(app.bundleIdentifier)
                result.append(app)
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads an `.app` bundle into an `InstalledApp` (nil if it has no bundle identifier).
    static func app(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return InstalledApp(bundleIdentifier: bid, name: name, url: url)
    }

    /// Best match for a spoken app name ("slack" → Slack), preferring exact, then prefix, then the
    /// shortest containing name (so "slack" picks "Slack" over "Slack Helper"). Pure; testable.
    static func bestMatch(forSpokenName query: String, in apps: [InstalledApp]) -> InstalledApp? {
        let q = query.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !q.isEmpty else { return nil }
        if let exact = apps.first(where: { $0.name.lowercased() == q }) { return exact }
        if let prefix = apps.first(where: { $0.name.lowercased().hasPrefix(q) }) { return prefix }
        return apps
            .filter { $0.name.lowercased().contains(q) }
            .min { $0.name.count < $1.name.count }
    }

    /// Icon for a discovered app.
    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Best-effort icon for an already-stored bundle id (so existing profiles show the app icon
    /// even though they only persist the identifier). Falls back to a generic app icon.
    static func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
