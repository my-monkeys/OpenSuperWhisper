import XCTest

@testable import OpenSuperWhisper

/// Preferences must not leak between parallel test processes. The scheme runs three testables
/// in parallel under one bundle identifier, so `UserDefaults.standard` is a single on-disk
/// domain shared between them (#59).
final class DefaultsStoreTests: XCTestCase {

    /// The whole fix rests on this: if the switch didn't happen, every other guarantee here is
    /// void and the suite is back to sharing one domain.
    func testTestsRunAgainstAPrivateSuite() {
        XCTAssertTrue(DefaultsStore.isRunningTests,
                      "XCTestConfigurationFilePath should be set while testing")
        XCTAssertNotEqual(DefaultsStore.current, UserDefaults.standard,
                          "tests must not write to the app's real domain")
    }

    /// Each process gets its own suite, which is what stops one host reading another's writes.
    func testSuiteNameIsPerProcess() {
        let mine = DefaultsStore.testSuiteName(for: ProcessInfo.processInfo.processIdentifier)
        let other = DefaultsStore.testSuiteName(for: ProcessInfo.processInfo.processIdentifier + 1)
        XCTAssertNotEqual(mine, other)
        XCTAssertTrue(mine.contains("\(ProcessInfo.processInfo.processIdentifier)"))
    }

    /// The sweep that cleans up old suites must not touch a sibling still running: the scheme
    /// runs testables in parallel, so deleting a live suite would recreate the interference
    /// this whole file exists to prevent.
    func testSweepSparesLiveProcesses() {
        let mine = DefaultsStore.testSuiteName(for: ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(DefaultsStore.isAbandoned(mine),
                       "this process is alive, so its suite must never be swept")
    }

    func testSweepClaimsSuitesOfDeadProcesses() {
        // PID 0 is the kernel's scheduler entry; no test host will ever own it, and it is not
        // a live process this call could match.
        let stale = "\(DefaultsStore.testSuitePrefix)999999"
        XCTAssertTrue(DefaultsStore.isAbandoned(stale))
    }

    /// A name that isn't a PID must not be mistaken for an abandoned suite.
    func testMalformedSuiteNameIsNotSwept() {
        XCTAssertFalse(DefaultsStore.isAbandoned("\(DefaultsStore.testSuitePrefix)notapid"))
    }

    /// The sweep has to actually remove the file, not merely intend to. cfprefsd caches domains
    /// and can write them back after a plain file delete, so this asserts the observable result.
    func testSweepRemovesAnAbandonedSuiteForReal() throws {
        let deadPID: Int32 = 999998
        let name = DefaultsStore.testSuiteName(for: deadPID)
        try XCTSkipUnless(DefaultsStore.isAbandoned(name), "PID \(deadPID) unexpectedly alive")

        let stale = try XCTUnwrap(UserDefaults(suiteName: name))
        stale.set("left behind", forKey: "sentinel")
        XCTAssertEqual(UserDefaults(suiteName: name)?.string(forKey: "sentinel"), "left behind")

        DefaultsStore.sweepSuitesFromPreviousRuns(
            keeping: DefaultsStore.testSuiteName(for: ProcessInfo.processInfo.processIdentifier))

        XCTAssertNil(UserDefaults(suiteName: name)?.string(forKey: "sentinel"),
                     "an abandoned suite must be gone after the sweep")
    }

    /// A preference written here must be invisible to the app's real domain, or the suite is
    /// decorative and a test run would still edit the user's own settings.
    func testWritesDoNotReachTheStandardDomain() {
        let key = "osw.defaultsStoreTests.\(UUID().uuidString)"
        defer { DefaultsStore.current.removeObject(forKey: key) }

        DefaultsStore.current.set("written-by-test", forKey: key)

        XCTAssertEqual(DefaultsStore.current.string(forKey: key), "written-by-test")
        XCTAssertNil(UserDefaults.standard.string(forKey: key),
                     "the app's domain must not see anything a test wrote")
    }

    /// AppPreferences goes through the same store, so setting one must not touch `.standard`.
    /// This is the path that actually mattered: a background task reading a restored preference
    /// is what kicked real engine work on a shared singleton mid-test.
    func testAppPreferencesWritesStayInTheSuite() {
        let original = AppPreferences.shared.selectedEngine
        defer { AppPreferences.shared.selectedEngine = original }

        let standardBefore = UserDefaults.standard.string(forKey: "selectedEngine")
        AppPreferences.shared.selectedEngine = "osw-test-sentinel"

        XCTAssertEqual(AppPreferences.shared.selectedEngine, "osw-test-sentinel")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedEngine"), standardBefore,
                       "AppPreferences must not write through to the real domain during tests")
    }
}
