import XCTest

@testable import OpenSuperWhisper

/// Objective-C exceptions surfacing as Swift errors.
///
/// `AVAudioEngine.installTap` raises an NSException when the input device is mid-reconfiguration.
/// Left to unwind through a main-actor task, it was swallowed by macOS 27 and the app crashed on
/// the next click in `swift_task_isCurrentExecutor`, with "Connecting..." stuck on the bubble.
final class ObjCExceptionTests: XCTestCase {

    func testARaisedExceptionBecomesAThrownError() {
        XCTAssertThrowsError(try ObjCExceptionError.catching {
            NSException(name: .internalInconsistencyException,
                        reason: "Failed to create tap due to format mismatch",
                        userInfo: nil).raise()
        }) { error in
            let caught = error as? ObjCExceptionError
            XCTAssertEqual(caught?.name, NSExceptionName.internalInconsistencyException.rawValue)
            XCTAssertEqual(caught?.reason, "Failed to create tap due to format mismatch")
        }
    }

    func testABlockThatReturnsNormallyThrowsNothingAndRuns() throws {
        var ran = false
        try ObjCExceptionError.catching { ran = true }
        XCTAssertTrue(ran)
    }

    /// The case that crashed: the exception raised inside a main-actor task. Afterwards the
    /// runtime must still know it is on the main executor, which is what the dangling state broke.
    @MainActor
    func testTheMainActorIsStillIntactAfterCatchingInsideATask() async throws {
        let task = Task { @MainActor in
            try ObjCExceptionError.catching {
                NSException(name: .genericException, reason: nil, userInfo: nil).raise()
            }
        }
        await XCTAssertThrowsErrorAsync(try await task.value)
        MainActor.assertIsolated()
    }

    private func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> Void,
                                           file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await expression()
            XCTFail("expected an error", file: file, line: line)
        } catch {}
    }
}
