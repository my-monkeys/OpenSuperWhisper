import XCTest

/// The commit-3 launch gate (plan Test Phase scenario 9). The assertion is trivial
/// by design — the value of this hosted bundle is the lifecycle it forces: compile,
/// link, install, launch, and dyld the iOS shell app on a Simulator. If the app
/// fails to link or launch (missing framework, bad rpath, unsigned embed), this
/// test never runs and the failure is loud.
final class OpenSuperWhisper_iOSLaunchTests: XCTestCase {
    func testAppProcessIsUp() {
        XCTAssertTrue(ProcessInfo.processInfo.processIdentifier > 0)
    }
}
