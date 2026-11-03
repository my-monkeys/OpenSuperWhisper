import AppKit
import OpenSuperWhisperCore

/// Offers to move the app into Applications when it runs from the disk image or from Downloads.
///
/// There is deliberately no "don't ask again": the places that trigger it are the ones where the
/// app cannot update itself or vanishes with the disk image, and a folder the user picked
/// (~/Apps, say) never triggers it. So the offer needs no preference.
enum MoveToApplications {

    // MARK: Decisions

    static func shouldOffer(bundleURL: URL, volumeIsReadOnly: Bool, downloadsURL: URL?) -> Bool {
        if volumeIsReadOnly { return true }
        let path = bundleURL.standardizedFileURL.path
        // Gatekeeper path randomization: a quarantined app launched from Downloads runs from a
        // read-only copy under here, so Sparkle cannot replace it.
        if path.contains("/AppTranslocation/") { return true }
        guard let downloadsPath = downloadsURL?.standardizedFileURL.path else { return false }
        return path.hasPrefix(downloadsPath + "/")
    }

    static func destinationFolder(canWrite: (URL) -> Bool, home: URL) -> URL {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return canWrite(system) ? system : home.appendingPathComponent("Applications", isDirectory: true)
    }

    // MARK: Launch entry point

    /// Returns true when the app is relaunching from its new place and the caller must stop
    /// launching.
    @MainActor
    static func offerIfNeeded() -> Bool {
        guard !DefaultsStore.isRunningTests else { return false }
        let bundleURL = Bundle.main.bundleURL
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard shouldOffer(bundleURL: bundleURL, volumeIsReadOnly: readOnly, downloadsURL: downloads) else {
            return false
        }
        guard confirmMove() else { return false }
        do {
            let destination = try copyToApplications(from: bundleURL)
            relaunch(from: destination)
            return true
        } catch {
            showFailure()
            return false
        }
    }

    // MARK: Side effects

    @MainActor
    private static func confirmMove() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Move OpenSuperWhisper to Applications?")
        alert.informativeText = String(localized: "From where it runs now, OpenSuperWhisper can't update itself, and it goes away when the disk image is ejected.")
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func showFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't move OpenSuperWhisper")
        alert.informativeText = String(localized: "Drag OpenSuperWhisper to your Applications folder from the disk image yourself.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private static func copyToApplications(from source: URL) throws -> URL {
        let fileManager = FileManager.default
        let folder = destinationFolder(canWrite: { fileManager.isWritableFile(atPath: $0.path) }, home: fileManager.homeDirectoryForCurrentUser)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)

        terminateOtherInstances(runningFrom: destination)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: source, to: destination)
        // The user already opened this notarized app once, so the copy must not ask again.
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        return destination
    }

    private static func terminateOtherInstances(runningFrom destination: URL) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL
        }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Opens the copy only after this process is gone, so the two never run side by side.
    @MainActor
    private static func relaunch(from destination: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, destination.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
