import XCTest
@testable import OpenSuperWhisper

/// Commit 0, scenario 4: pin WhisperModelManager's disk behavior against an injected
/// temp directory (the `init(modelsDirectory:)` seam). Network paths are deliberately
/// out of scope EXCEPT the already-downloaded short-circuit arm, which is reachable
/// without any network.
final class WhisperModelManagerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WMMTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeManager() -> WhisperModelManager {
        WhisperModelManager(modelsDirectory: tempDir)
    }

    func testInitCreatesTheModelsDirectory() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path),
                       "precondition: temp dir must not exist before init")
        _ = makeManager()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "init must create the injected models directory")
    }

    func testDefaultModelCopyIsInertWithoutBundleResource() {
        // CHARACTERIZATION OF CURRENT BEHAVIOR (verified 2026-07-19): ggml-tiny.en.bin is a
        // repo-root file reference in NO target's resources phase — the built app bundle has
        // no ggml resource, so copyDefaultModelIfNeeded's Bundle.main lookup finds nothing
        // and copies nothing. This test PINS that inert behavior: if a future change bundles
        // the model (the intended production behavior), this test must flip loudly to a
        // copy-happens assertion.
        _ = makeManager()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        if Bundle.main.url(forResource: "ggml-tiny.en", withExtension: "bin") != nil {
            XCTAssertEqual(contents, ["ggml-tiny.en.bin"],
                           "bundle resource present → default model must be copied in")
        } else {
            XCTAssertTrue(contents.isEmpty,
                          "no bundle resource → no default model copy (current inert behavior)")
        }
    }

    func testGetAvailableModelsReturnsOnlyBinFilesSortedByName() {
        _ = makeManager()
        for name in ["ggml-tiny.bin", "ggml-base.bin", "ggml-large.bin"] {
            FileManager.default.createFile(atPath: tempDir.appendingPathComponent(name).path, contents: Data())
        }
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("notes.txt").path, contents: Data())
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("ggml-noext").path, contents: Data())

        let names = makeManager().getAvailableModels().map { $0.lastPathComponent }
        XCTAssertEqual(names, ["ggml-base.bin", "ggml-large.bin", "ggml-tiny.bin"],
                       "only .bin files, sorted ascending by last path component")
    }

    func testGetAvailableModelsOnEmptyDirectoryReturnsEmpty() {
        XCTAssertEqual(makeManager().getAvailableModels(), [])
    }

    func testIsModelDownloadedReflectsFilePresence() {
        let manager = makeManager()
        XCTAssertFalse(manager.isModelDownloaded(name: "ggml-base.bin"))
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("ggml-base.bin").path, contents: Data())
        XCTAssertTrue(manager.isModelDownloaded(name: "ggml-base.bin"))
    }

    func testReInitOnPopulatedDirectoryKeepsExistingModels() {
        _ = makeManager()
        let modelFile = tempDir.appendingPathComponent("ggml-base.bin")
        FileManager.default.createFile(atPath: modelFile.path, contents: Data("model".utf8))

        let second = makeManager()  // idempotent re-init: create-if-needed + copy-if-needed are no-ops
        XCTAssertTrue(second.isModelDownloaded(name: "ggml-base.bin"))
        XCTAssertEqual(try? Data(contentsOf: modelFile), Data("model".utf8),
                       "existing model content must be untouched by re-init")
    }

    func testDownloadModelShortCircuitsWhenFileAlreadyExists() async throws {
        let manager = makeManager()
        let existing = tempDir.appendingPathComponent("ggml-base.bin")
        let original = Data("already-here".utf8)
        try original.write(to: existing)

        let progressSeen = expectation(description: "short-circuit reports progress 1.0")
        // A URL that would fail any real fetch — proving this arm never touches the network.
        let unreachable = URL(string: "file:///definitely/not/a/real/model.bin")!
        try await manager.downloadModel(url: unreachable, name: "ggml-base.bin") { progress in
            if progress == 1.0 { progressSeen.fulfill() }
        }
        await fulfillment(of: [progressSeen], timeout: 5)

        XCTAssertEqual(try? Data(contentsOf: existing), original,
                       "short-circuit arm must leave the existing file untouched")
    }

    func testCancelDownloadWithNoActiveTaskIsANoOp() {
        // Pins the bookkeeping contract: cancelling an unknown name neither crashes nor throws.
        makeManager().cancelDownload(name: "never-started.bin")
    }
}
