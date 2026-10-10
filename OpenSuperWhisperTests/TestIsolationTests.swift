import XCTest

@testable import OpenSuperWhisper

/// The test host is the app, so it runs the app's launch code and reaches the app's storage.
/// Preferences, Keychain items and files must all resolve somewhere private to the test process,
/// and the formula the shipped app uses for its files must not move while they do.
final class TestIsolationTests: XCTestCase {

    private static let shippedBundleID = "fr.my-monkey.opensuperwhisper"

    private func testRoot() throws -> URL {
        try XCTUnwrap(AppIdentity.storageRoot())
    }

    private func assertInsideTestRoot(_ url: URL?, _ what: String,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let path = try XCTUnwrap(url, what, file: file, line: line).path
        let root = try testRoot().path
        let realDirectory = try XCTUnwrap(AppIdentity.applicationSupportDirectory()).path

        XCTAssertTrue(path.hasPrefix(root + "/"),
                      "\(what) is outside the test storage root: \(path)", file: file, line: line)
        XCTAssertFalse(path.hasPrefix(realDirectory + "/"),
                       "\(what) points into the user's real data: \(path)", file: file, line: line)
    }

    // MARK: - Detection

    /// Both signals hold in the host, so losing either one alone still leaves the switch on.
    func testBothTestSignalsArePresent() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
        XCTAssertNotNil(NSClassFromString("XCTestCase"))
        XCTAssertTrue(DefaultsStore.isRunningTests)
    }

    func testPreferencesAreNotTheStandardDomain() {
        XCTAssertFalse(DefaultsStore.current === UserDefaults.standard)
    }

    func testKeychainUsesTheTestService() {
        XCTAssertEqual(Keychain.service, "\(AppIdentity.bundleID).tests")
        XCTAssertNotEqual(Keychain.service, Self.shippedBundleID)
    }

    // MARK: - Storage root

    func testStorageRootIsAPerProcessTemporaryDirectory() throws {
        let root = try testRoot()

        XCTAssertEqual(root.deletingLastPathComponent().standardizedFileURL.path,
                       FileManager.default.temporaryDirectory.standardizedFileURL.path)
        XCTAssertEqual(root.lastPathComponent,
                       DefaultsStore.testSuiteName(for: ProcessInfo.processInfo.processIdentifier))
        XCTAssertNotEqual(root, AppIdentity.applicationSupportDirectory())
    }

    func testEveryStorageLocationResolvesInsideTheTestRoot() throws {
        try assertInsideTestRoot(Recording.recordingsDirectory, "recordings folder")
        try assertInsideTestRoot(WhisperModelManager.shared.modelsDirectory, "whisper models")
        try assertInsideTestRoot(LLMModelManager.shared.modelsDirectory, "LLM models")
        try assertInsideTestRoot(SenseVoiceModelManager.shared.modelDirectory, "SenseVoice model")
        try assertInsideTestRoot(AgentBridge.directory, "agents folder")
    }

    /// The store opens its database at launch, so the file has to exist where the root says.
    @MainActor
    func testRecordingStoreOpenedItsDatabaseInTheTestRoot() throws {
        _ = RecordingStore.shared
        let database = RecordingStore.databaseURL(in: try testRoot())

        try assertInsideTestRoot(database, "recordings database")
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
    }

    // MARK: - The shipped formula

    /// Whisper model paths are persisted as absolute strings, so these are contracts with every
    /// existing install. Expected values are spelled out rather than derived from the code.
    func testProductionPathsKeepTheirLegacySpelling() throws {
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ).path
        let expectedRoot = "\(applicationSupport)/fr.my-monkey.opensuperwhisper"
        let root = try XCTUnwrap(AppIdentity.applicationSupportDirectory(bundleID: Self.shippedBundleID))

        XCTAssertEqual(root.path, expectedRoot)
        XCTAssertEqual(AppIdentity.applicationSupportDirectory()?.path, expectedRoot)
        XCTAssertEqual(Recording.recordingsDirectory(in: root).path, "\(expectedRoot)/recordings")
        XCTAssertEqual(RecordingStore.databaseURL(in: root).path, "\(expectedRoot)/recordings.sqlite")
        XCTAssertEqual(WhisperModelManager.modelsDirectory(in: root).path, "\(expectedRoot)/whisper-models")
        XCTAssertEqual(LLMModelManager.modelsDirectory(in: root).path, "\(expectedRoot)/llm-models")
        XCTAssertEqual(SenseVoiceModelManager.modelDirectory(in: root).path, "\(expectedRoot)/sensevoice-model")
    }
}
