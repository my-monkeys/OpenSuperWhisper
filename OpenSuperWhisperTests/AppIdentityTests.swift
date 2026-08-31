import XCTest

@testable import OpenSuperWhisper

/// Finding our own bundle when the path we were launched by is a symlink pointing into it.
///
/// The path arithmetic is what is testable here. The rest depends on how the process was started,
/// which a test cannot stage, so these cover the shape of the walk rather than a live launch.
final class AppIdentityTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: - Climbing out of the bundle

    func testAnExecutableInsideABundleFindsIt() {
        let found = AppIdentity.enclosingBundleURL(
            forExecutableAt: url("/Applications/OpenSuperWhisper.app/Contents/MacOS/OpenSuperWhisper"))

        XCTAssertEqual(found?.path, "/Applications/OpenSuperWhisper.app")
    }

    func testABareBinaryHasNoBundle() {
        XCTAssertNil(AppIdentity.enclosingBundleURL(forExecutableAt: url("/usr/local/bin/whatever")))
    }

    /// The layout has to be the real one, not merely deep enough. Three levels up from anywhere
    /// lands on *something*, and returning it would name a directory that is not a bundle.
    func testADeepPathThatIsNotABundleIsRejected() {
        XCTAssertNil(AppIdentity.enclosingBundleURL(
            forExecutableAt: url("/opt/homebrew/Cellar/thing/bin/thing")))
    }

    func testTheContentsAndMacOSLevelsMustBeNamedThat() {
        XCTAssertNil(AppIdentity.enclosingBundleURL(
            forExecutableAt: url("/Applications/Foo.app/Resources/bin/Foo")))
    }

    func testAnyAppBundleWorksNotJustOurs() {
        let found = AppIdentity.enclosingBundleURL(
            forExecutableAt: url("/Applications/Some Other.app/Contents/MacOS/Some Other"))

        XCTAssertEqual(found?.lastPathComponent, "Some Other.app")
    }

    // MARK: - The identifier itself

    /// Whatever happens, callers get a string. Five places used to force-unwrap this to build a
    /// directory path, so nil was not merely wrong, it was a trap waiting for the CLI.
    func testTheIdentifierIsNeverNil() {
        XCTAssertFalse(AppIdentity.bundleID.isEmpty)
    }

    /// Under the test host the main bundle is present, so the real identifier must win over the
    /// hardcoded fallback. If this ever fails, the resolution order got inverted.
    func testTheRealBundleWinsOverTheFallback() throws {
        let identifier = try XCTUnwrap(Bundle.main.bundleIdentifier)

        XCTAssertEqual(AppIdentity.bundleID, identifier)
    }

    func testApplicationSupportIsNamedAfterTheIdentifier() throws {
        let directory = try XCTUnwrap(AppIdentity.applicationSupportDirectory())

        XCTAssertEqual(directory.lastPathComponent, AppIdentity.bundleID)
        XCTAssertTrue(directory.path.contains("Application Support"))
    }
}
