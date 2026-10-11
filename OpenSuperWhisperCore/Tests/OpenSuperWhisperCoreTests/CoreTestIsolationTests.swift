import XCTest
@testable import OpenSuperWhisperCore

/// The core test process keeps off the user's preferences, Keychain items and files, as the
/// hosted test host does.
final class CoreTestIsolationTests: CoreTestCase {

    func testTheProcessIsATestProcess() {
        XCTAssertTrue(DefaultsStore.isRunningTests)
        XCTAssertFalse(DefaultsStore.current === UserDefaults.standard)

        let suiteName = DefaultsStore.testSuiteName(for: ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(suiteName.hasPrefix(DefaultsStore.testSuitePrefix))
        let key = "core-tests-\(UUID().uuidString)"
        DefaultsStore.current.set("written", forKey: key)
        defer { DefaultsStore.current.removeObject(forKey: key) }
        XCTAssertEqual(UserDefaults(suiteName: suiteName)?.string(forKey: key), "written")
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func testKeychainUsesTheTestService() {
        XCTAssertNotEqual(Keychain.service, Keychain.productionService)
        XCTAssertTrue(Keychain.service.hasSuffix(".tests"), Keychain.service)
    }

#if os(macOS)
    /// An unhosted test on the iOS Simulator has no keychain entitlement, so the round trip only
    /// runs on macOS. The account is new to this test and deleted by it.
    func testKeychainRoundTripStaysInTheTestService() {
        let account = "core-tests-\(UUID().uuidString)"
        defer { Keychain.set(nil, for: account) }

        Keychain.set("secret", for: account)
        XCTAssertEqual(Keychain.read(account), "secret")
        XCTAssertEqual(Keychain.itemQuery(for: account)[kSecAttrService as String] as? String,
                       Keychain.service)

        Keychain.set(nil, for: account)
        XCTAssertNil(Keychain.read(account))
    }
#endif

    func testStorageRootIsUnderTheTemporaryDirectory() {
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let root = CoreTestEnvironment.storageRoot
        XCTAssertTrue(root.resolvingSymlinksInPath().path.hasPrefix(tmp), root.path)
        XCTAssertEqual(root, AppIdentity.storageRoot())
        XCTAssertNotEqual(root, AppIdentity.applicationSupportDirectory())
    }
}
