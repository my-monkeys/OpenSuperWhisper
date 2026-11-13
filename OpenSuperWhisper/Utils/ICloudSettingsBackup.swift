import Foundation
import OpenSuperWhisperCore

/// Keeps a copy of the portable settings in the user's iCloud Drive, to restore on another Mac.
///
/// A plain file in `~/Library/Mobile Documents/com~apple~CloudDocs/OpenSuperWhisper/`: the app is
/// not sandboxed, so no CloudKit and no entitlement. The file is the same `SettingsArchive` the
/// manual export and the gist use, plus the Mac's name. Writing is one way, this Mac to the
/// cloud; restoring is always an explicit choice, so two Macs never overwrite each other's
/// settings behind anyone's back.
///
/// Every touch of the folder runs off the main thread (`ICloudBackupFiles`): iCloud Drive answers
/// in its own time, and a read of a file it is still fetching waits inside `open()` until it has.
/// On the main thread that froze the whole app, shortcut and menu bar included.
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

    /// What the Settings row shows, gathered in one trip off the main thread.
    struct Status: Sendable {
        var isAvailable = false
        var isDownloadPending = false
        var lastBackup: SettingsArchive.Origin?
    }

    private let files: ICloudBackupFiles
    private let defaults: UserDefaults
    private let hostName: String
    private let appVersion: String
    private let debounce: Duration
    private var observer: NSObjectProtocol?
    private var pendingWrite: Task<Void, Never>?
    private(set) var isRestoring = false

    /// `readFile` is how the backup file is read; a test passes a slow one to stand in for
    /// iCloud Drive taking its time.
    init(folder: URL = ICloudSettingsBackup.defaultFolder,
         defaults: UserDefaults = DefaultsStore.current,
         hostName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
         appVersion: String = UpdateChecker.currentVersion,
         debounce: Duration = .seconds(2),
         readFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.files = ICloudBackupFiles(folder: folder, readFile: readFile)
        self.defaults = defaults
        self.hostName = hostName
        self.appVersion = appVersion
        self.debounce = debounce
    }

    var folder: URL { files.folder }
    var fileURL: URL { files.fileURL }
    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func isAvailable() async -> Bool {
        await offMain { $0.isAvailable }
    }

    func isDownloadPending() async -> Bool {
        await offMain { $0.isDownloadPending }
    }

    func status() async -> Status {
        await offMain { files in
            guard files.isAvailable else { return Status() }
            let pending = files.isDownloadPending
            let origin = pending ? nil : files.read().flatMap(SettingsArchive.origin(of:))
            return Status(isAvailable: true, isDownloadPending: pending, lastBackup: origin)
        }
    }

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
            _ = try? await writeIfChanged()
        }
    }

    /// Returns whether the file was rewritten. Identical settings leave it alone, so iCloud does
    /// not sync a new version (and the "last backup" date does not move) for a change that never
    /// travels, such as a local preference.
    @discardableResult
    func writeIfChanged() async throws -> Bool {
        guard !isRestoring else { return false }
        let data = try SettingsArchive.export(from: defaults, appVersion: appVersion, host: hostName)
        return try await offMainThrowing { try $0.writeIfChanged(data) }
    }

    // MARK: - Restoring

    /// The backup in the folder, nil when there is none.
    func backup() async throws -> Backup? {
        guard let data = await offMain({ $0.read() }) else { return nil }
        let values = try SettingsArchive.read(data)
        guard let origin = SettingsArchive.origin(of: data) else { throw SettingsArchive.ReadError.notASettingsFile }
        return Backup(origin: origin, values: values)
    }

    /// The backup's origin when another Mac wrote it: what turning the switch on here would
    /// replace, and may not be meant to.
    func backupFromAnotherMac() async -> SettingsArchive.Origin? {
        guard let data = await offMain({ $0.read() }),
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

    // MARK: - Off the main thread

    private func offMain<T: Sendable>(_ work: @escaping @Sendable (ICloudBackupFiles) -> T) async -> T {
        let files = files
        return await Task.detached(priority: .utility) { work(files) }.value
    }

    private func offMainThrowing<T: Sendable>(_ work: @escaping @Sendable (ICloudBackupFiles) throws -> T) async throws -> T {
        let files = files
        return try await Task.detached(priority: .utility) { try work(files) }.value
    }
}

/// The backup folder's file work, each call blocking for as long as iCloud Drive takes, so
/// `ICloudSettingsBackup` only ever runs it on a background task.
struct ICloudBackupFiles: Sendable {
    let folder: URL
    let readFile: @Sendable (URL) throws -> Data

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

    /// The backup's bytes, nil when there is none or it is not downloaded yet.
    func read() -> Data? {
        guard !isDownloadPending else { return nil }
        return try? readFile(fileURL)
    }

    func writeIfChanged(_ data: Data) throws -> Bool {
        guard isAvailable, !isDownloadPending else { return false }
        if let existing = try? readFile(fileURL),
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
}
