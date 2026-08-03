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

    /// S-11 (PR #57 review cycle 1): the Cycle-1 shell claims to embed ggml-tiny.en.bin.
    /// The hosted bundle is the only place that can prove the resource actually made it
    /// into the installed .app — a missing Copy-Resources entry compiles and launches
    /// fine, and Cycle 2's model load would fail only at runtime.
    func testBundledWhisperModelPresent() {
        XCTAssertNotNil(
            Bundle.main.url(forResource: "ggml-tiny.en", withExtension: "bin"),
            "ggml-tiny.en.bin must be embedded in the iOS app bundle (Cycle 2 loads it)"
        )
    }
}
