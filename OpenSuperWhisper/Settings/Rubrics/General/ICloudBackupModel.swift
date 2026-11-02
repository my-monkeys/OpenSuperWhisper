import OpenSuperWhisperCore
import SwiftUI

/// The "Back up to iCloud Drive" switch and the restore row. The file work lives in
/// `ICloudSettingsBackup`; this decides what turning the switch on means on a Mac that is not
/// the one that made the backup.
@MainActor
final class ICloudBackupModel: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isEnabled = false
    /// A backup is in iCloud Drive but not downloaded to this Mac yet.
    @Published private(set) var isDownloading = false
    /// When and where the backup in iCloud Drive was last written. Nil when there is none.
    @Published private(set) var lastBackup: SettingsArchive.Origin?
    /// Another Mac's backup found when the switch was turned on; the person decides its fate.
    @Published var conflict: SettingsArchive.Origin?
    @Published private(set) var errorMessage: String?

    private let backup: ICloudSettingsBackup

    init(backup: ICloudSettingsBackup = .shared) {
        self.backup = backup
    }

    func refresh() {
        isAvailable = backup.isAvailable
        isEnabled = backup.isEnabled && isAvailable
        isDownloading = isAvailable && backup.isDownloadPending
        lastBackup = (try? backup.backup())?.origin
    }

    func setEnabled(_ on: Bool) {
        errorMessage = nil
        guard on else { return turnOff() }
        // Its author is unknown until it lands, and writing now could replace a good backup.
        guard !backup.isDownloadPending else {
            isDownloading = true
            errorMessage = String(localized: "Downloading the backup from iCloud…")
            return
        }
        if let other = backup.backupFromAnotherMac() {
            conflict = other
        } else {
            turnOn()
        }
    }

    /// "Replace it with this Mac's settings".
    func replaceBackup() {
        conflict = nil
        turnOn()
    }

    /// "Restore it": the choice was the confirmation, so the values are ready to apply.
    func restoreFromConflict() -> SettingsTransferModel.PendingImport? {
        conflict = nil
        let pending = restoreRequest()
        if pending != nil { turnOn() }
        return pending
    }

    /// The backup, ready for the same confirmation and import path as the manual file.
    func restoreRequest() -> SettingsTransferModel.PendingImport? {
        do {
            guard let found = try backup.backup() else {
                errorMessage = String(localized: "No backup in iCloud Drive yet.")
                return nil
            }
            return SettingsTransferModel.PendingImport(values: found.values, savedAt: found.origin.exportedAt,
                                                       host: found.origin.host)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func turnOn() {
        AppPreferences.shared.iCloudSettingsBackupEnabled = true
        do {
            try backup.writeIfChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private func turnOff() {
        AppPreferences.shared.iCloudSettingsBackupEnabled = false
        refresh()
    }
}
