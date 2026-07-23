import XCTest
import WhisperCore
@testable import OpenSuperWhisper

/// Maintainer review (PR #57, CHANGES_REQUESTED): pin the consent seam's wiring
/// POINT. The silent-drop window: confirmEnableHistory was wired in
/// applicationDidFinishLaunching while application(_:openFiles:) can be delivered
/// earlier on a file-open-at-launch — addFileToQueue then hit the unwired
/// fail-safe (nil = cancel) and silently dropped a file the pre-extraction inline
/// NSAlert would have prompted on. The fix wires the seam in
/// applicationWillFinishLaunching: AppKit delivers open-files events BETWEEN
/// willFinish and didFinish, so every GUI path finds the closure wired. This test
/// pins exactly that: willFinishLaunching alone (no didFinishLaunching) wires it.
///
/// (Wiring in AppDelegate.init() was rejected at compile time: init() is
/// nonisolated while the seam is @MainActor-isolated; the delegate callback is
/// the SDK-annotated MainActor hook with the documented before-openFiles
/// ordering.)
///
/// Hygiene: the pin runs against TranscriptionQueue.shared (the wiring target) —
/// the prior value is saved/restored so app-hosted runs (where the real delegate
/// already wired it) and later classes see untouched state. The wired closure is
/// never invoked (it shows a modal NSAlert).
@MainActor
final class AppDelegateConsentWiringTests: XCTestCase {

    private var savedWiring: (() -> Bool)?

    override func setUp() {
        super.setUp()
        savedWiring = TranscriptionQueue.shared.confirmEnableHistory
        TranscriptionQueue.shared.confirmEnableHistory = nil
    }

    override func tearDown() {
        TranscriptionQueue.shared.confirmEnableHistory = savedWiring
        super.tearDown()
    }

    func testWillFinishLaunchingWiresConsentSeamBeforeOpenEvents() {
        XCTAssertNil(TranscriptionQueue.shared.confirmEnableHistory,
                     "precondition: seam unwired before willFinishLaunching")

        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: .init("test")))

        XCTAssertNotNil(TranscriptionQueue.shared.confirmEnableHistory,
                        "applicationWillFinishLaunching must wire the consent seam — application(_:openFiles:) is delivered before applicationDidFinishLaunching")
    }
}
