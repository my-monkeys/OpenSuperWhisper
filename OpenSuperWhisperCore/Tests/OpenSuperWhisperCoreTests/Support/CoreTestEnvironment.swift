import Foundation
@testable import OpenSuperWhisperCore

/// The one place the core tests install a configuration. It goes through
/// `CoreConfiguration.replaceForTesting(_:)`, not `install(_:)`: install traps on a second call,
/// and the replace tests swap the slot and put this configuration back.
enum CoreTestEnvironment {
    static let preferences = TestPreferences()

    /// The core's own per-process test root: NSTemporaryDirectory()/<bundleID>.tests.<pid>,
    /// emptied on first use and swept by pid like the hosted roots.
    static let storageRoot: URL = AppIdentity.storageRoot()!

    /// The simulator runs whisper and llama on the CPU, as the iPhone app will in the background.
    static let computePolicy: ComputePolicy = {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        return .automatic
        #endif
    }()

    static var configuration: CoreConfiguration {
        CoreConfiguration(preferences: { preferences },
                          storageRoot: { storageRoot },
                          vadModelPath: { Fixtures.sileroVAD.path },
                          textFormatter: { $0 },
                          computePolicy: computePolicy,
                          makeSettings: { Fixtures.pinnedSettings() },
                          confirmEnableHistory: { false })
    }

    private static let installed: Void = {
        precondition(DefaultsStore.isRunningTests, "core tests must run as a test process")
        precondition(Keychain.service != Keychain.productionService
                     && Keychain.service.hasSuffix(".tests"), "Keychain is not on the test service")
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        precondition(storageRoot.resolvingSymlinksInPath().path.hasPrefix(tmp), "storage root outside tmp")
        precondition(!CoreConfiguration.isInstalled, "a configuration was installed before the test environment")
        CoreConfiguration.replaceForTesting(configuration)
    }()

    /// Safe to call from every test class and suite: a static let runs its initializer once,
    /// thread-safely.
    static func install() { _ = installed }
}
