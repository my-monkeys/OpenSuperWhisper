import Foundation

/// Where every preference in the app is read and written.
///
/// In the app this is `UserDefaults.standard`, unchanged. Under XCTest it becomes a suite
/// private to the running process, because the macOS scheme runs its testables in parallel and
/// they all share the app's bundle identifier — so `.standard` is *one on-disk domain shared
/// between test processes*. A write in one is visible in another, and a background task that
/// outlives its test can read those restored preferences and act on a shared singleton while a
/// test in a different process is asserting on it. That produced failures that were green on
/// isolated rerun and impossible to trust. (#59)
///
/// The switch is automatic rather than opt-in: a channel that has to be remembered will be
/// forgotten by the next test that starts background work.
enum DefaultsStore {
    static let current: UserDefaults = {
        guard isRunningTests else { return .standard }
        let name = testSuiteName(for: ProcessInfo.processInfo.processIdentifier)
        guard let suite = UserDefaults(suiteName: name) else { return .standard }
        // Start from nothing: a suite left behind by a crashed run would otherwise seed this one.
        suite.removePersistentDomain(forName: name)
        sweepSuitesFromPreviousRuns(keeping: name)
        return suite
    }()

    /// True while the process is hosting XCTest. `XCTestConfigurationFilePath` is set by the
    /// test runner and absent in a normal launch, including a Debug build the user runs.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var testSuitePrefix: String {
        "\(Bundle.main.bundleIdentifier ?? "fr.my-monkey.opensuperwhisper").tests."
    }

    static func testSuiteName(for pid: Int32) -> String { "\(testSuitePrefix)\(pid)" }

    /// Empties suites left by earlier test processes. Done on the way in rather than at exit:
    /// `atexit` never ran here, because the test host is killed rather than allowed to return
    /// from `main`.
    ///
    /// It clears contents, not files: cfprefsd caches the domain and writes an empty plist back
    /// after the delete, so Preferences keeps a handful of ~40-byte stubs. Harmless, and not
    /// worth fighting the daemon over — what matters is that no stale *value* survives to be
    /// read by a later run.
    static func sweepSuitesFromPreviousRuns(keeping current: String) {
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Preferences")
        guard let preferences,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: preferences.path)
        else { return }

        for entry in entries where entry.hasPrefix(testSuitePrefix) && entry.hasSuffix(".plist") {
            let name = String(entry.dropLast(".plist".count))
            guard name != current, isAbandoned(name) else { continue }
            UserDefaults.standard.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(entry))
        }
    }

    /// Whether a suite belongs to a process that is gone. The scheme runs testables in
    /// parallel, so a live sibling's suite must survive the sweep — deleting it would recreate
    /// the very cross-process interference this file exists to stop.
    static func isAbandoned(_ suiteName: String) -> Bool {
        guard let pid = Int32(suiteName.dropFirst(testSuitePrefix.count)) else { return false }
        // kill(pid, 0) probes for existence without signalling; ESRCH means no such process.
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}
