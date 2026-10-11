import AppKit
import OpenSuperWhisperCore

/// One row of Style → Per app: everything customised for one app, or the model chosen for one
/// site. Built from the three stores that already existed (insertion rules, formatting profiles,
/// model rules), which keep their formats; the row is only a view over them.
struct PerAppEntry: Identifiable, Equatable {
    /// The bundle identifier as stored. Empty for a rule saved before an app was chosen.
    let bundleID: String
    /// Set for a per-site model rule ("bundleID|host"), which is its own row.
    let host: String?
    let appName: String
    var insertion: AppInsertionRule?
    var profiles: [AppContextProfile] = []
    var model: DictationModelOption?

    var id: String { PerAppEntry.groupKey(bundleID) + (host.map { "|\($0)" } ?? "") }
    var isSite: Bool { host != nil }
    var hasBundle: Bool { !bundleID.isEmpty }
    var isEmpty: Bool { insertion == nil && profiles.isEmpty && model == nil }

    var title: String { host.map { "\(appName) · \($0)" } ?? appName }

    /// Insertion and formatting rules match bundle identifiers case-insensitively.
    static func groupKey(_ bundleID: String) -> String { bundleID.lowercased() }
}

enum PerAppEntries {
    /// Merges the stores into rows, apps by name, each app's site rules right after it.
    /// `pending` are apps just added from the picker that nothing is set for yet.
    static func build(insertionRules: [AppInsertionRule],
                      profiles: [AppContextProfile],
                      modelRules: [String: DictationModelOption],
                      pending: [InstalledApp]) -> [PerAppEntry] {
        var apps: [String: PerAppEntry] = [:]
        var sites: [PerAppEntry] = []

        func app(_ bundleID: String, name: String?) -> PerAppEntry {
            let key = PerAppEntry.groupKey(bundleID)
            if let existing = apps[key] { return existing }
            return PerAppEntry(bundleID: bundleID, host: nil, appName: displayName(bundleID, stored: name))
        }

        for (key, model) in modelRules {
            let (bundleID, host) = AppContextRuleRow.parse(key)
            if let host {
                sites.append(PerAppEntry(bundleID: bundleID, host: host,
                                         appName: displayName(bundleID, stored: nil), model: model))
            } else {
                var entry = app(bundleID, name: nil)
                entry.model = model
                apps[PerAppEntry.groupKey(bundleID)] = entry
            }
        }
        for rule in insertionRules {
            var entry = app(rule.bundleIdentifier, name: rule.appName)
            // The first match wins at dictation time, so a duplicate is not shown as the rule.
            if entry.insertion == nil { entry.insertion = rule }
            apps[PerAppEntry.groupKey(rule.bundleIdentifier)] = entry
        }
        for profile in profiles {
            var entry = app(profile.bundleIdentifier, name: profile.appName)
            entry.profiles.append(profile)
            apps[PerAppEntry.groupKey(profile.bundleIdentifier)] = entry
        }
        for installed in pending where apps[PerAppEntry.groupKey(installed.bundleIdentifier)] == nil {
            apps[PerAppEntry.groupKey(installed.bundleIdentifier)] =
                PerAppEntry(bundleID: installed.bundleIdentifier, host: nil, appName: installed.name)
        }

        return (Array(apps.values) + sites).sorted(by: order)
    }

    private static func order(_ a: PerAppEntry, _ b: PerAppEntry) -> Bool {
        let byName = a.appName.localizedCaseInsensitiveCompare(b.appName)
        if byName != .orderedSame { return byName == .orderedAscending }
        if a.bundleID != b.bundleID { return a.bundleID < b.bundleID }
        return (a.host ?? "") < (b.host ?? "")
    }

    /// The name a rule was saved with, else the installed app's, else the bundle identifier.
    private static func displayName(_ bundleID: String, stored: String?) -> String {
        if let stored, !stored.isEmpty { return stored }
        guard !bundleID.isEmpty else { return String(localized: "No app chosen") }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

/// Writes a row's changes back to the store each setting lives in.
@MainActor
struct PerAppStore {
    let viewModel: SettingsViewModel

    private func matches(_ bundleID: String, _ entry: PerAppEntry) -> Bool {
        PerAppEntry.groupKey(bundleID) == PerAppEntry.groupKey(entry.bundleID)
    }

    /// nil removes the app's insertion rule, so the global "Paste instead of typing" decides.
    func setInsertion(_ mode: AppInsertionMode?, for entry: PerAppEntry) {
        guard let mode else {
            viewModel.appInsertionRules.removeAll { matches($0.bundleIdentifier, entry) }
            return
        }
        if let index = viewModel.appInsertionRules.firstIndex(where: { matches($0.bundleIdentifier, entry) }) {
            viewModel.appInsertionRules[index].mode = mode
        } else {
            viewModel.appInsertionRules.append(
                AppInsertionRule(bundleIdentifier: entry.bundleID, appName: entry.appName, mode: mode))
        }
    }

    func setTypingPace(_ milliseconds: Int?, for entry: PerAppEntry) {
        guard let index = viewModel.appInsertionRules.firstIndex(where: { matches($0.bundleIdentifier, entry) })
        else { return }
        viewModel.appInsertionRules[index].typingPaceMilliseconds = milliseconds
    }

    /// nil removes the rule, so the model in effect stays whatever was chosen last.
    func setModel(_ model: DictationModelOption?, for entry: PerAppEntry) {
        if let model {
            AppContextModelRules.set(model, for: entry.bundleID, host: entry.host)
        } else {
            AppContextModelRules.remove(bundleID: entry.bundleID, host: entry.host)
        }
    }

    func addProfile(for entry: PerAppEntry) {
        viewModel.appContextProfiles.append(
            AppContextProfile(bundleIdentifier: entry.bundleID, appName: entry.appName, instructions: ""))
    }

    func removeProfile(_ id: UUID) {
        viewModel.appContextProfiles.removeAll { $0.id == id }
    }

    /// An app row leaves every store; a site row only drops its model rule.
    func remove(_ entry: PerAppEntry) {
        if !entry.isSite {
            viewModel.appInsertionRules.removeAll { matches($0.bundleIdentifier, entry) }
            viewModel.appContextProfiles.removeAll { matches($0.bundleIdentifier, entry) }
        }
        if entry.hasBundle && (entry.isSite || entry.model != nil) {
            AppContextModelRules.remove(bundleID: entry.bundleID, host: entry.host)
        }
    }

    /// Points the app's rules at another app, as "Change the app" did in the old lists.
    func reassign(_ entry: PerAppEntry, to app: InstalledApp) {
        for index in viewModel.appInsertionRules.indices where matches(viewModel.appInsertionRules[index].bundleIdentifier, entry) {
            viewModel.appInsertionRules[index].bundleIdentifier = app.bundleIdentifier
            viewModel.appInsertionRules[index].appName = app.name
        }
        for index in viewModel.appContextProfiles.indices where matches(viewModel.appContextProfiles[index].bundleIdentifier, entry) {
            viewModel.appContextProfiles[index].bundleIdentifier = app.bundleIdentifier
            viewModel.appContextProfiles[index].appName = app.name
        }
        if entry.hasBundle, let model = entry.model {
            AppContextModelRules.remove(bundleID: entry.bundleID)
            AppContextModelRules.set(model, for: app.bundleIdentifier)
        }
    }
}
