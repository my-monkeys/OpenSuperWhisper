import XCTest
@testable import OpenSuperWhisperCore

/// The test environment's configuration is the one installed, the core's singletons captured it,
/// and `replaceForTesting(_:)` swaps the slot and hands back what it replaced.
///
/// No test here installs nil on the process's slot: a background read in between would trap and
/// end the run. The hosted `CoreConfigurationTests` covers the slot's nil semantics on a private
/// instance.
final class CoreConfigurationInstallTests: CoreTestCase {

    private var scratchRoots: [URL] = []

    override func tearDown() {
        scratchRoots.forEach { try? FileManager.default.removeItem(at: $0) }
        scratchRoots = []
        super.tearDown()
    }

    func testTheTestEnvironmentIsInstalled() throws {
        XCTAssertTrue(CoreConfiguration.isInstalled)
        let current = CoreConfiguration.current
        XCTAssertTrue(current.preferences() === CoreTestEnvironment.preferences)
        XCTAssertEqual(current.storageRoot(), CoreTestEnvironment.storageRoot)
        let vad = try XCTUnwrap(current.vadModelPath())
        XCTAssertEqual(vad, Fixtures.sileroVAD.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vad), vad)
#if targetEnvironment(simulator)
        XCTAssertEqual(current.computePolicy, .cpuOnly)
#else
        XCTAssertEqual(current.computePolicy, .automatic)
#endif
    }

    /// A provider nobody reads is the same as no provider. Installing a stub and reading it back
    /// through `CoreAccess` proves the path the field-term reducer will use is live; a test that
    /// only asserted the value round-trips through the configuration would pass on a dead seam.
    ///
    /// The stub answers to the language it is given, so this also pins that the clip's language
    /// reaches the dictionary rather than one the host read for itself — the defect that made a
    /// French dictation judge its field against an English preference.
    @MainActor
    func testTheSpellingProviderIsReadThroughTheConfiguration() {
        var configuration = CoreTestEnvironment.configuration
        configuration.fieldTermSpelling = { language in
            DictionaryCandidates.Spelling(knows: { $0 == "known" || $0 == language },
                                          correctsTypo: { $0 == "typo" })
        }
        CoreConfiguration.replaceForTesting(configuration)
        defer { CoreConfiguration.replaceForTesting(CoreTestEnvironment.configuration) }

        let spelling = CoreAccess.fieldTermSpelling("fr")
        XCTAssertTrue(spelling.knows("known"))
        XCTAssertFalse(spelling.knows("unknown"))
        XCTAssertTrue(spelling.knows("fr"), "the provider was not told the language")
        XCTAssertTrue(spelling.correctsTypo("typo"))
        XCTAssertFalse(spelling.correctsTypo("known"))
    }

    func testReplaceForTestingSwapsAndReturnsThePrevious() {
        let probeRoot = makeScratchRoot()

        withProbe(root: probeRoot) { previous in
            XCTAssertEqual(previous?.storageRoot(), CoreTestEnvironment.storageRoot)
            XCTAssertEqual(CoreAccess.storageRoot, probeRoot)
        }

        XCTAssertEqual(CoreAccess.storageRoot, CoreTestEnvironment.storageRoot)
        XCTAssertTrue(CoreConfiguration.current.preferences() === CoreTestEnvironment.preferences)
    }

    func testSingletonsCapturedTheTestConfiguration() {
        let root = CoreTestEnvironment.storageRoot.standardizedFileURL.path
        XCTAssertEqual(WhisperEngine.vadModelPath, Fixtures.sileroVAD.path)
        XCTAssertTrue(LLMModelManager.shared.modelsDirectory.standardizedFileURL.path.hasPrefix(root))
        XCTAssertTrue(WhisperModelManager.shared.modelsDirectory.standardizedFileURL.path.hasPrefix(root))
    }

    /// `Recording.url` reads the installed root on every call (deviation 9), so it follows a
    /// replacement and comes back with the environment.
    func testRecordingsDirectoryFollowsTheInstalledRoot() {
        let probeRoot = makeScratchRoot()

        withProbe(root: probeRoot) { _ in
            XCTAssertEqual(Recording.recordingsDirectory, probeRoot.appendingPathComponent("recordings"))
        }

        XCTAssertEqual(Recording.recordingsDirectory,
                       CoreTestEnvironment.storageRoot.appendingPathComponent("recordings"))
    }

    func testDesignatedInitialisersIgnoreTheInstalledConfiguration() {
        let installedRoot = makeScratchRoot()
        let injectedRoot = makeScratchRoot()

        withProbe(root: installedRoot) { _ in
            XCTAssertEqual(WhisperModelManager(storageRoot: injectedRoot).modelsDirectory,
                           injectedRoot.appendingPathComponent("whisper-models"))
            XCTAssertEqual(LLMModelManager(storageRoot: injectedRoot).modelsDirectory,
                           injectedRoot.appendingPathComponent("llm-models"))
            XCTAssertEqual(SenseVoiceModelManager(storageRoot: injectedRoot).modelDirectory,
                           injectedRoot.appendingPathComponent("sensevoice-model"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: installedRoot.appendingPathComponent("whisper-models").path))
    }

    // MARK: - Helpers

    private func makeScratchRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreConfigurationInstallTests-\(UUID().uuidString)", isDirectory: true)
        scratchRoots.append(root)
        return root
    }

    /// Installs the environment's configuration with another storage root for the body, and puts
    /// the environment back even when the body fails.
    private func withProbe(root: URL, _ body: (CoreConfiguration?) -> Void) {
        var probe = CoreTestEnvironment.configuration
        probe.storageRoot = { root }
        let previous = CoreConfiguration.replaceForTesting(probe)
        defer { CoreConfiguration.replaceForTesting(CoreTestEnvironment.configuration) }
        body(previous)
    }
}
