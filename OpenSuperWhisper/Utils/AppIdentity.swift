import Foundation

/// Who we are, resolved so that it survives being launched through a symlink.
///
/// `Bundle.main` is derived from the path the process was launched by, and that path is the
/// symlink rather than what it points at. Homebrew installs the CLI as
/// `/opt/homebrew/bin/opensuperwhisper` pointing into the app bundle, so invoking it that way
/// makes the main bundle `/opt/homebrew/bin`, which has no Info.plist. The identifier then comes
/// back nil, and everything keyed on it goes somewhere else: the preferences domain, the model
/// directory, the recordings directory. The CLI reported loading an engine nobody had selected
/// because it was reading an empty set of preferences (#88).
enum AppIdentity {

    /// Last resort, used only when neither the main bundle nor the resolved executable can say.
    /// A fork that renames the bundle gets the right answer from the resolution above this.
    static let fallbackBundleID = "fr.my-monkey.opensuperwhisper"

    /// The app's bundle identifier. Never nil, and the same value whichever path was used to
    /// start the process.
    static let bundleID: String = {
        if let identifier = Bundle.main.bundleIdentifier { return identifier }

        if let executable = Bundle.main.executableURL,
           let bundleURL = enclosingBundleURL(forExecutableAt: executable),
           let identifier = Bundle(url: bundleURL)?.bundleIdentifier {
            return identifier
        }

        return fallbackBundleID
    }()

    /// The `.app` containing an executable, given the path it was launched by.
    ///
    /// Resolves symlinks first, since the whole point is that the launch path is a link, then
    /// climbs `Contents/MacOS` to reach the bundle. Returns nil for an executable that is not
    /// inside an app bundle at all, which is the case under `swift test` and for a bare binary.
    static func enclosingBundleURL(forExecutableAt executable: URL) -> URL? {
        let resolved = executable.resolvingSymlinksInPath()
        let macOS = resolved.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()

        guard macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app"
        else { return nil }

        return bundle
    }

    /// The app's directory inside Application Support, where models and recordings live.
    ///
    /// Named after the bundle identifier, which is why resolving that identifier properly matters
    /// beyond the preferences: launched through the symlink this used to be a different directory,
    /// and the five places that built it force-unwrapped the identifier, so they were one step
    /// away from trapping rather than merely looking in the wrong place.
    ///
    /// This is the formula alone, whatever process runs it, so a test can pin it: whisper model
    /// paths are persisted as absolute strings, and a different spelling of this directory would
    /// orphan every model the user picked. Code that reads or writes files asks `storageRoot()`.
    static func applicationSupportDirectory(bundleID: String = AppIdentity.bundleID) -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleID)
    }

    /// Where the app keeps its files: the recordings database and folder, the model folders, the
    /// agents folder. `applicationSupportDirectory()` in a normal launch.
    ///
    /// Under XCTest it is a directory private to the process, for the reason `DefaultsStore`
    /// swaps its suite: the test host is the app, so it used to open the user's real recordings
    /// database at launch and create folders next to their models. FluidAudio keeps its models in
    /// its own cache outside this directory, which this does not move.
    static func storageRoot() -> URL? {
        DefaultsStore.isRunningTests ? testStorageRoot : applicationSupportDirectory()
    }

    /// Named after the process like the defaults suite, and emptied the first time it is used,
    /// since a pid gets reused and a directory left by an earlier run would seed this one.
    private static let testStorageRoot: URL = {
        let temporary = FileManager.default.temporaryDirectory
        sweepTestStorageFromPreviousRuns(in: temporary)
        let name = DefaultsStore.testSuiteName(for: ProcessInfo.processInfo.processIdentifier)
        let root = temporary.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    /// Every test process leaves a database behind, and the host is killed rather than allowed
    /// to clean up. Same rule as the defaults sweep: a parallel sibling's root is still in use.
    static func sweepTestStorageFromPreviousRuns(in temporary: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: temporary.path)
        else { return }

        for entry in entries
        where entry.hasPrefix(DefaultsStore.testSuitePrefix) && DefaultsStore.isAbandoned(entry) {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(entry))
        }
    }
}
