import XCTest
import os
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The core reaches the app only through the configuration `AppMain.main` installs on its first
/// line. These check that the host installed the macOS values, and that installing or reading a
/// configuration evaluates none of its providers, so AppPreferences is still created when
/// something first reads it.
final class CoreConfigurationTests: XCTestCase {

    /// The suite's check that `main` installs before anything else runs: the test host is the app.
    func testTheHostInstalledTheMacOSConfiguration() {
        XCTAssertTrue(CoreConfiguration.isInstalled)
        let configuration = CoreConfiguration.current

        XCTAssertTrue(configuration.preferences() === AppPreferences.shared)
        XCTAssertEqual(configuration.storageRoot(), AppIdentity.storageRoot())

        let bundled = Bundle(for: WhisperEngine.self).path(forResource: "ggml-silero-v5.1.2", ofType: "bin")
        XCTAssertNotNil(configuration.vadModelPath())
        XCTAssertEqual(configuration.vadModelPath(), bundled)

        XCTAssertEqual(configuration.computePolicy, .automatic)

        let sample = "你好world这是一个测试"
        XCTAssertEqual(configuration.textFormatter(sample), AutocorrectWrapper.format(sample))
    }

    func testInstallingAndReadingASlotEvaluatesNoProvider() {
        let calls = ProviderCalls()
        let slot = ConfigurationSlot()

        XCTAssertTrue(slot.install(Self.probe(counting: calls)))
        XCTAssertEqual(calls.total, 0)

        XCTAssertNotNil(slot.configuration)
        XCTAssertEqual(calls.total, 0)

        XCTAssertFalse(slot.install(Self.probe(counting: calls)))
        XCTAssertEqual(calls.total, 0)
    }

    /// Compiles only when the package is built with `DEBUG`. Never called: the hosted suite must
    /// not replace the configuration its singletons already captured.
    func testTheTestingReplacementExistsInDebug() {
        let _: (CoreConfiguration?) -> CoreConfiguration? = CoreConfiguration.replaceForTesting
    }

    private static func probe(counting calls: ProviderCalls) -> CoreConfiguration {
        CoreConfiguration(
            preferences: { calls.record(); return AppPreferences.shared },
            storageRoot: { calls.record(); return FileManager.default.temporaryDirectory },
            vadModelPath: { calls.record(); return nil },
            textFormatter: { calls.record(); return $0 },
            computePolicy: .cpuOnly,
            makeSettings: { calls.record(); return Settings(freshInstallLanguage: "en") },
            confirmEnableHistory: { calls.record(); return false })
    }
}

private final class ProviderCalls: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var total: Int { count.withLock { $0 } }
    func record() { count.withLock { $0 += 1 } }
}
