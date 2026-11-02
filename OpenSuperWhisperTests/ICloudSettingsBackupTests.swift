import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The iCloud Drive backup, with a temporary folder standing in for iCloud Drive.
@MainActor
final class ICloudSettingsBackupTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudBackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "ICloudSettingsBackupTests.\(UUID().uuidString)")
        defaults.set(true, forKey: ICloudSettingsBackup.enabledKey)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBackup(host: String = "Studio", debounce: Duration = .milliseconds(20),
                            folder: URL? = nil) -> ICloudSettingsBackup {
        ICloudSettingsBackup(folder: folder ?? root.appendingPathComponent("OpenSuperWhisper"),
                             defaults: defaults, hostName: host, appVersion: "1.2.3", debounce: debounce)
    }

    func testWritesTheArchiveWithItsMetadata() throws {
        defaults.set("fr", forKey: "whisperLanguage")
        let backup = makeBackup()

        XCTAssertTrue(try backup.writeIfChanged())

        let stored = try XCTUnwrap(try backup.backup())
        XCTAssertEqual(stored.values["whisperLanguage"] as? String, "fr")
        XCTAssertEqual(stored.origin.host, "Studio")
        XCTAssertEqual(stored.origin.app, "1.2.3")
        XCTAssertNotNil(stored.origin.exportedAt)
    }

    func testIdenticalSettingsDoNotRewriteTheFile() throws {
        defaults.set(0.4, forKey: "temperature")
        let backup = makeBackup()
        XCTAssertTrue(try backup.writeIfChanged())
        let before = try Data(contentsOf: backup.fileURL)

        XCTAssertFalse(try backup.writeIfChanged())
        XCTAssertEqual(try Data(contentsOf: backup.fileURL), before)

        defaults.set(0.5, forKey: "temperature")
        XCTAssertTrue(try backup.writeIfChanged())
    }

    func testALocalPreferenceNeverReachesTheFile() throws {
        let backup = makeBackup()
        XCTAssertTrue(try backup.writeIfChanged())

        defaults.set(true, forKey: "debugMode")
        XCTAssertFalse(try backup.writeIfChanged())
        XCTAssertNil(try backup.backup()?.values["debugMode"])
    }

    func testAChangeIsWrittenOnceThingsSettle() async throws {
        let backup = makeBackup()
        backup.start()
        defaults.set("de", forKey: "whisperLanguage")
        defaults.set(true, forKey: "autoCopyToClipboard")

        try await Task.sleep(for: .milliseconds(400))

        let stored = try XCTUnwrap(try backup.backup())
        XCTAssertEqual(stored.values["whisperLanguage"] as? String, "de")
        XCTAssertEqual(stored.values["autoCopyToClipboard"] as? Bool, true)
    }

    func testNothingIsWrittenWhileTheSwitchIsOff() async throws {
        defaults.set(false, forKey: ICloudSettingsBackup.enabledKey)
        let backup = makeBackup()
        backup.start()
        defaults.set("de", forKey: "whisperLanguage")

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.fileURL.path))
    }

    func testAnotherMacsBackupIsRecognisedAndOwnIsNot() throws {
        defaults.set("fr", forKey: "whisperLanguage")
        try makeBackup(host: "Laptop").writeIfChanged()

        XCTAssertEqual(makeBackup(host: "Studio").backupFromAnotherMac()?.host, "Laptop")
        XCTAssertNil(makeBackup(host: "Laptop").backupFromAnotherMac())
    }

    func testNoBackupMeansNoConflictAndNothingToRestore() throws {
        let backup = makeBackup()
        XCTAssertNil(backup.backupFromAnotherMac())
        XCTAssertNil(try backup.backup())
    }

    func testMissingICloudDriveDisablesTheBackup() throws {
        let missing = root.appendingPathComponent("com~apple~CloudDocs").appendingPathComponent("OpenSuperWhisper")
        let backup = makeBackup(folder: missing)

        XCTAssertFalse(backup.isAvailable)
        XCTAssertFalse(try backup.writeIfChanged())
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testRestoreAppliesTheValuesAndDoesNotRewriteTheBackup() async throws {
        let laptop = UserDefaults(suiteName: "ICloudSettingsBackupTests.laptop.\(UUID().uuidString)")!
        laptop.set("it", forKey: "whisperLanguage")
        let laptopBackup = ICloudSettingsBackup(folder: root.appendingPathComponent("OpenSuperWhisper"),
                                                defaults: laptop, hostName: "Laptop", appVersion: "1.2.3")
        try laptopBackup.writeIfChanged()
        let before = try Data(contentsOf: laptopBackup.fileURL)

        let studio = makeBackup(host: "Studio")
        studio.start()
        studio.restore(try XCTUnwrap(try studio.backup()).values)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(defaults.string(forKey: "whisperLanguage"), "it")
        XCTAssertEqual(try Data(contentsOf: studio.fileURL), before, "the restored settings are the backup's own")
    }

    /// Optimize Mac Storage leaves a hidden `.<name>.icloud` stub where the file will land.
    func testAPlaceholderIsABackupThatIsNotHereYetAndIsNeverOverwritten() throws {
        let backup = makeBackup()
        let folder = backup.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let placeholder = folder.appendingPathComponent(".\(SettingsArchive.fileName).icloud")
        try Data("stub".utf8).write(to: placeholder)
        defaults.set("fr", forKey: "whisperLanguage")

        XCTAssertTrue(backup.isDownloadPending)
        XCTAssertFalse(try backup.writeIfChanged())
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.fileURL.path))
        XCTAssertNil(try backup.backup())

        try FileManager.default.removeItem(at: placeholder)
        XCTAssertFalse(backup.isDownloadPending)
        XCTAssertTrue(try backup.writeIfChanged())
    }

    func testSwitchingOnWaitsForADownloadingBackup() throws {
        let backup = makeBackup()
        try FileManager.default.createDirectory(at: backup.folder, withIntermediateDirectories: true)
        try Data().write(to: backup.folder.appendingPathComponent(".\(SettingsArchive.fileName).icloud"))
        defaults.set(false, forKey: ICloudSettingsBackup.enabledKey)

        let model = ICloudBackupModel(backup: backup)
        model.refresh()
        model.setEnabled(true)

        XCTAssertTrue(model.isDownloading)
        XCTAssertFalse(backup.isEnabled)
    }
}
