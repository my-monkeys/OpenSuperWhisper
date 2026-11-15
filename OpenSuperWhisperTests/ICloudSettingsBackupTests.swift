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
                            folder: URL? = nil,
                            readFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) -> ICloudSettingsBackup {
        ICloudSettingsBackup(folder: folder ?? root.appendingPathComponent("OpenSuperWhisper"),
                             defaults: defaults, hostName: host, appVersion: "1.2.3", debounce: debounce,
                             readFile: readFile)
    }

    func testWritesTheArchiveWithItsMetadata() async throws {
        defaults.set("fr", forKey: "whisperLanguage")
        let backup = makeBackup()

        let wrote = try await backup.writeIfChanged()
        XCTAssertTrue(wrote)

        let stored = try await XCTUnwrapAsync(try await backup.backup())
        XCTAssertEqual(stored.values["whisperLanguage"] as? String, "fr")
        XCTAssertEqual(stored.origin.host, "Studio")
        XCTAssertEqual(stored.origin.app, "1.2.3")
        XCTAssertNotNil(stored.origin.exportedAt)
    }

    func testIdenticalSettingsDoNotRewriteTheFile() async throws {
        defaults.set(0.4, forKey: "temperature")
        let backup = makeBackup()
        var wrote = try await backup.writeIfChanged()
        XCTAssertTrue(wrote)
        let before = try Data(contentsOf: backup.fileURL)

        wrote = try await backup.writeIfChanged()
        XCTAssertFalse(wrote)
        XCTAssertEqual(try Data(contentsOf: backup.fileURL), before)

        defaults.set(0.5, forKey: "temperature")
        wrote = try await backup.writeIfChanged()
        XCTAssertTrue(wrote)
    }

    func testALocalPreferenceNeverReachesTheFile() async throws {
        let backup = makeBackup()
        var wrote = try await backup.writeIfChanged()
        XCTAssertTrue(wrote)

        defaults.set(true, forKey: "debugMode")
        wrote = try await backup.writeIfChanged()
        XCTAssertFalse(wrote)
        let stored = try await backup.backup()
        XCTAssertNil(stored?.values["debugMode"])
    }

    func testAChangeIsWrittenOnceThingsSettle() async throws {
        let backup = makeBackup()
        backup.start()
        defaults.set("de", forKey: "whisperLanguage")
        defaults.set(true, forKey: "autoCopyToClipboard")

        try await Task.sleep(for: .milliseconds(400))

        let stored = try await XCTUnwrapAsync(try await backup.backup())
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

    func testAnotherMacsBackupIsRecognisedAndOwnIsNot() async throws {
        defaults.set("fr", forKey: "whisperLanguage")
        try await makeBackup(host: "Laptop").writeIfChanged()

        let fromStudio = await makeBackup(host: "Studio").backupFromAnotherMac()
        let fromLaptop = await makeBackup(host: "Laptop").backupFromAnotherMac()
        XCTAssertEqual(fromStudio?.host, "Laptop")
        XCTAssertNil(fromLaptop)
    }

    func testNoBackupMeansNoConflictAndNothingToRestore() async throws {
        let backup = makeBackup()
        let other = await backup.backupFromAnotherMac()
        let stored = try await backup.backup()
        XCTAssertNil(other)
        XCTAssertNil(stored)
    }

    func testMissingICloudDriveDisablesTheBackup() async throws {
        let missing = root.appendingPathComponent("com~apple~CloudDocs").appendingPathComponent("OpenSuperWhisper")
        let backup = makeBackup(folder: missing)

        let available = await backup.isAvailable()
        let wrote = try await backup.writeIfChanged()
        XCTAssertFalse(available)
        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testRestoreAppliesTheValuesAndDoesNotRewriteTheBackup() async throws {
        let laptop = UserDefaults(suiteName: "ICloudSettingsBackupTests.laptop.\(UUID().uuidString)")!
        laptop.set("it", forKey: "whisperLanguage")
        let laptopBackup = ICloudSettingsBackup(folder: root.appendingPathComponent("OpenSuperWhisper"),
                                                defaults: laptop, hostName: "Laptop", appVersion: "1.2.3")
        try await laptopBackup.writeIfChanged()
        let before = try Data(contentsOf: laptopBackup.fileURL)

        let studio = makeBackup(host: "Studio")
        studio.start()
        let found = try await XCTUnwrapAsync(try await studio.backup())
        studio.restore(found.values)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(defaults.string(forKey: "whisperLanguage"), "it")
        XCTAssertEqual(try Data(contentsOf: studio.fileURL), before, "the restored settings are the backup's own")
    }

    /// Optimize Mac Storage leaves a hidden `.<name>.icloud` stub where the file will land.
    func testAPlaceholderIsABackupThatIsNotHereYetAndIsNeverOverwritten() async throws {
        let backup = makeBackup()
        let folder = backup.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let placeholder = folder.appendingPathComponent(".\(SettingsArchive.fileName).icloud")
        try Data("stub".utf8).write(to: placeholder)
        defaults.set("fr", forKey: "whisperLanguage")

        var pending = await backup.isDownloadPending()
        var wrote = try await backup.writeIfChanged()
        let stored = try await backup.backup()
        XCTAssertTrue(pending)
        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.fileURL.path))
        XCTAssertNil(stored)

        try FileManager.default.removeItem(at: placeholder)
        pending = await backup.isDownloadPending()
        wrote = try await backup.writeIfChanged()
        XCTAssertFalse(pending)
        XCTAssertTrue(wrote)
    }

    func testSwitchingOnWaitsForADownloadingBackup() async throws {
        let backup = makeBackup()
        try FileManager.default.createDirectory(at: backup.folder, withIntermediateDirectories: true)
        try Data().write(to: backup.folder.appendingPathComponent(".\(SettingsArchive.fileName).icloud"))
        defaults.set(false, forKey: ICloudSettingsBackup.enabledKey)

        let model = ICloudBackupModel(backup: backup)
        await model.refresh()
        await model.setEnabled(true)

        XCTAssertTrue(model.isDownloading)
        XCTAssertFalse(backup.isEnabled)
    }

    /// iCloud Drive can keep a read waiting inside `open()` for as long as it likes. Opening
    /// Settings used to make that wait on the main thread, which froze the whole app.
    func testASlowICloudDriveLeavesTheMainThreadFree() async throws {
        defaults.set("fr", forKey: "whisperLanguage")
        try await makeBackup(host: "Laptop").writeIfChanged()
        let slow = makeBackup(readFile: { url in
            Thread.sleep(forTimeInterval: 0.5)
            return try Data(contentsOf: url)
        })
        let model = ICloudBackupModel(backup: slow)

        let clock = ContinuousClock()
        let started = clock.now
        let refreshing = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        let mainWaited = clock.now - started

        XCTAssertLessThan(mainWaited, .milliseconds(300), "the main thread waited for iCloud Drive")
        await refreshing.value
        XCTAssertEqual(model.lastBackup?.host, "Laptop")
    }

    func testTheTestHostStaysOutOfTheRealICloudDrive() async throws {
        let folder = ICloudSettingsBackup.shared.folder.path
        let storage = try XCTUnwrap(AppIdentity.storageRoot()).path
        let available = await ICloudSettingsBackup.shared.isAvailable()

        XCTAssertFalse(folder.contains("Mobile Documents"), folder)
        XCTAssertTrue(folder.hasPrefix(storage), folder)
        XCTAssertFalse(available)
    }

    private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?,
                                   file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let resolved = try await value()
        return try XCTUnwrap(resolved, file: file, line: line)
    }
}
