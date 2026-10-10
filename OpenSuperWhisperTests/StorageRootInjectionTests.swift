import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The model managers and the recording store take their storage root through their
/// initialiser, so a host or a test can point them anywhere. `shared` passes the configured
/// root; these build their own on a scratch directory.
final class StorageRootInjectionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageRootInjectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWhisperModelManagerCreatesItsFolderUnderTheGivenRoot() {
        let manager = WhisperModelManager(storageRoot: root)

        XCTAssertEqual(manager.modelsDirectory, root.appendingPathComponent("whisper-models"))
        XCTAssertTrue(directoryExists(root.appendingPathComponent("whisper-models")))
    }

    func testLLMModelManagerCreatesItsFolderUnderTheGivenRoot() {
        let manager = LLMModelManager(storageRoot: root)

        XCTAssertEqual(manager.modelsDirectory, root.appendingPathComponent("llm-models"))
        XCTAssertTrue(directoryExists(root.appendingPathComponent("llm-models")))
    }

    func testSenseVoiceModelManagerLooksUnderTheGivenRoot() {
        let manager = SenseVoiceModelManager(storageRoot: root)

        XCTAssertEqual(manager.modelDirectory, root.appendingPathComponent("sensevoice-model"))
    }

    @MainActor
    func testRecordingStoreOpensItsDatabaseUnderTheGivenRoot() {
        _ = RecordingStore(storageRoot: root)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("recordings.sqlite").path))
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
