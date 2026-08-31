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
    static func applicationSupportDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleID)
    }
}
