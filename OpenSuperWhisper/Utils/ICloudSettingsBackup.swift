import Foundation
import OpenSuperWhisperCore

/// Keeps a copy of the portable settings in the user's iCloud Drive, to restore on another Mac.
///
/// A plain file in `~/Library/Mobile Documents/com~apple~CloudDocs/OpenSuperWhisper/`: the app is
/// not sandboxed, so no CloudKit and no entitlement. The file is the same `SettingsArchive` the
/// manual export and the gist use, plus the Mac's name. Writing is one way, this Mac to the
/// cloud; restoring is always an explicit choice, so two Macs never overwrite each other's
/// settings behind anyone's back.
@MainActor
final class ICloudSettingsBackup {
    static let shared = ICloudSettingsBackup()
    static let enabledKey = "iCloudSettingsBackupEnabled"

    nonisolated static var defaultFolder: URL {
        iCloudDrive.appendingPathComponent("OpenSuperWhisper", isDirectory: true)
    }

    /// The test host is the app, and the Settings window it renders refreshes this backup: it
    /// read the person's real file there, and once hung a whole run on the main thread inside
    /// `open()`. Under XCTest iCloud Drive is a folder in the process's own storage that is never
    /// created, so the backup reads as iCloud Drive turned off, as it does on CI.
    nonisolated private static var iCloudDrive: URL {
        guard DefaultsStore.isRunningTests else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        }
        let root = AppIdentity.storageRoot() ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("iCloud Drive", isDirectory: true)
    }

    struct Backup {
        let origin: SettingsArchive.Origin
        let values: [String: Any]
    }

    let folder: URL
    private let defaults: UserDefaults
    private let hostName: String
    private let appVersion: String
    private let debounce: Duration
    private var observer: NSObjectProtocol?
    private var pendingWrite: Task<Void, Never>?
    private(set) var isRestoring = false

    init(folder: URL = ICloudSettingsBackup.defaultFolder,
         defaults: UserDefaults = DefaultsStore.current,
         hostName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
         appVersion: String = UpdateChecker.currentVersion,
         debounce: Duration = .seconds(2)) {
        self.folder = folder
        self.defaults = defaults
        self.hostName = hostName
        self.appVersion = appVersion
        self.debounce = debounce
    }

    var fileURL: URL { folder.appendingPathComponent(SettingsArchive.fileName) }

    /// iCloud Drive is on when its folder exists; the backup folder inside it is ours to create.
    var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// With Optimize Mac Storage, a backup another Mac made can exist here only as a hidden
    /// `.<name>.icloud` placeholder, or as a file iCloud has not downloaded yet. Either way a
    /// backup exists, just not readable: it must never be taken for "no backup" and overwritten.
    /// Asking iCloud to fetch it is repeated at each check until it lands.
    var isDownloadPending: Bool {
        let placeholder = folder.appendingPathComponent(".\(SettingsArchive.fileName).icloud")
        let status = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        guard FileManager.default.fileExists(atPath: placeholder.path) || (status != nil && status != .current)
        else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        return true
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    // MARK: - Writing

    /// Watches the preferences for the life of the app; a write only happens while the switch is on.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleWrite() }
        }
        scheduleWrite()
    }

    /// Preferences change in bursts (a slider, an import), so the file is written once things settle.
    func scheduleWrite() {
        guard isEnabled, !isRestoring else { return }
        pendingWrite?.cancel()
        pendingWrite = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            _ = try? writeIfChanged()
        }
    }

    /// Returns whether the file was rewritten. Identical settings leave it alone, so iCloud does
    /// not sync a new version (and the "last backup" date does not move) for a change that never
    /// travels, such as a local preference.
    @discardableResult
    func writeIfChanged() throws -> Bool {
        guard isAvailable, !isRestoring, !isDownloadPending else { return false }
        let data = try SettingsArchive.export(from: defaults, appVersion: appVersion, host: hostName)
        if let existing = try? Data(contentsOf: fileURL),
           let old = try? SettingsArchive.read(existing),
           NSDictionary(dictionary: old).isEqual(to: try SettingsArchive.read(data)) {
            return false
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Atomic: a temporary file in the same folder, then renamed over the old one, so iCloud
        // never uploads or hands another Mac a half-written file.
        try data.write(to: fileURL, options: .atomic)
        return true
    }

    // MARK: - Restoring

    /// The backup in the folder, nil when there is none.
    func backup() throws -> Backup? {
        guard !isDownloadPending, let data = try? Data(contentsOf: fileURL) else { return nil }
        let values = try SettingsArchive.read(data)
        guard let origin = SettingsArchive.origin(of: data) else { throw SettingsArchive.ReadError.notASettingsFile }
        return Backup(origin: origin, values: values)
    }

    /// The backup's origin when another Mac wrote it: what turning the switch on here would
    /// replace, and may not be meant to.
    func backupFromAnotherMac() -> SettingsArchive.Origin? {
        guard let data = try? Data(contentsOf: fileURL),
              let origin = SettingsArchive.origin(of: data),
              origin.host != hostName
        else { return nil }
        return origin
    }

    /// Applies restored values without the backup writing in the middle of it: the notifications
    /// the new values raise are not this Mac's own edits.
    func restore(_ values: [String: Any]) {
        isRestoring = true
        pendingWrite?.cancel()
        SettingsArchive.apply(values, to: defaults)
        isRestoring = false
    }
}
