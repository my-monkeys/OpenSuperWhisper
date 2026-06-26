import XCTest
@testable import OpenSuperWhisper

/// Regression tests for the Indicator layout-recursion stack-overflow (#11).
///
/// The crash was an unbounded SwiftUI/AppKit layout feedback loop on the
/// recording-stop transition: `NSHostingController` `sizingOptions=[.preferredContentSize]`
/// drives `NSHostingView.updateAnimatedWindowSize` on every SwiftUI size change, and a
/// `didResizeNotification` observer called `reposition()→setFrameOrigin()` synchronously
/// inside the in-flight layout pass, re-entering `updateAnimatedWindowSize` unboundedly
/// (~6,795 levels → 56 MB guard page → SIGSEGV).
///
/// The fix (commit on `IndicatorWindowManager.swift`):
///   (1) observer add/remove symmetry — added fresh on `show()`, removed in `hide()`;
///   (2) `scheduleReposition` dispatches `reposition` to the next runloop turn so
///       `setFrameOrigin` never runs inside the layout pass that posted the notification;
///   (3) `isRepositionPending` recursion-guard coalesces a nested burst.
///
/// These tests assert the OBSERVABLE contracts of that fix, not the private flags:
///   - observer removed on hide() → no reposition after teardown
///   - setFrameOrigin deferred out of the layout pass (no synchronous re-entry)
///   - no runaway layout on the stop transition (count-budget + wall-clock timeout)
///   - pill-growth preserved (window still resizes to fit growing content)
///
/// The observable seam is `NSWindow.setFrameOrigin(_:)`, counted via a swizzle. A
/// counter that increments from within a `didResizeNotification` observer's synchronous
/// call frame proves re-entry; a counter that only increments on a later runloop turn
/// proves the deferral.
///
/// `./run.sh build` is a hard prereq — the test target links the app target which links
/// the native dylibs (autocorrect / onnxruntime / libwhisper). Build artifacts must be
/// present before this target compiles/links.
///
/// `@MainActor`: `IndicatorWindowManager` and `IndicatorViewModel` are main-actor-isolated,
/// so all `show()`/`hide()`/`window`/`viewModel` access must run on the main actor. XCTest
/// runs `@MainActor` test classes' methods on the main actor, which is also where the AppKit
/// windowing + `DispatchQueue.main.async` deferred reposition fire — so the runloop draining
/// below actually pumps the same queue the fix dispatches to.
@MainActor
final class IndicatorLayoutRecursionTests: XCTestCase {

    private var swizzleToken: NSObjectProtocol?
    /// Increments on every `NSWindow.setFrameOrigin(_:)` call, tagged with whether the
    /// call happened on the main runloop's current pass vs a deferred turn.
    private var setFrameOriginCount = 0

    override func setUp() {
        super.setUp()
        setFrameOriginCount = 0
        FrameOriginCounter.installIfNeeded()
        FrameOriginCounter.shared.reset()
    }

    override func tearDown() {
        // Ensure no indicator window lingers between tests (singleton state isolation).
        IndicatorWindowManager.shared.stopForce()
        // Drain any deferred scheduleReposition dispatched during the test.
        drainMainRunloop(seconds: 0.2)
        super.tearDown()
    }

    // MARK: - P0: observer removed on hide()

    /// After show() → hide() (+ draining the async Task), posting a didResizeNotification
    /// to the indicator window must NOT cause any further setFrameOrigin call. This proves
    /// the observer is removed in hide() and does not linger across cycles (the
    /// cross-cycle half of the #11 crash chain).
    ///
    /// Counter-test-by-revert (source-only revert of fix commit `eed859c`):
    ///   this test FAILS pre-fix (observer never removed → reposition still fires after
    ///   hide). Coupled to the regression. See also testSetFrameOriginDeferredOutOfLayoutPass
    ///   and testObserverActiveWhileShown_SingleCoalescedReposition, which fail pre-fix too.
    func testObserverRemovedOnHide_NoFurtherReposition() {
        let manager = IndicatorWindowManager.shared
        let vm = manager.show(nearPoint: nil)
        XCTAssertNotNil(manager.window, "show() must install a window")

        // Tear down synchronously where possible: hide() enqueues a Task, so drive the
        // VM through the delegate path and drain.
        vm.cleanup()
        manager.hide()
        drainMainRunloop(seconds: 0.3) // let hide()'s Task complete + any deferred reposition settle

        let baseline = FrameOriginCounter.shared.count

        // Simulate the stop-time settle storm: post a burst of resizes to the window.
        // If the observer were still installed, scheduleReposition → reposition →
        // setFrameOrigin would fire on the next runloop turn.
        if let window = manager.window {
            for _ in 0..<5 {
                NotificationCenter.default.post(
                    name: NSWindow.didResizeNotification, object: window)
            }
        }
        drainMainRunloop(seconds: 0.3) // give any deferred dispatch room to fire

        let delta = FrameOriginCounter.shared.count - baseline
        XCTAssertEqual(delta, 0,
            "Observer must be removed on hide(); a didResizeNotification after teardown "
            + "must not trigger setFrameOrigin (got \(delta) call(s)).")
    }

    /// The observer IS active while shown: a resize while the indicator is visible must
    /// still re-anchor (exactly one deferred setFrameOrigin, coalesced from a burst).
    /// This is the positive-path counter-test to testObserverRemovedOnHide — it proves
    /// the delta=0 above is because the observer is gone, not because counting is broken.
    func testObserverActiveWhileShown_SingleCoalescedReposition() {
        let manager = IndicatorWindowManager.shared
        _ = manager.show(nearPoint: nil)
        guard let window = manager.window else {
            XCTFail("show() must install a window"); return
        }

        drainMainRunloop(seconds: 0.1) // let the initial show() reposition settle
        let baseline = FrameOriginCounter.shared.count

        // Burst of resizes while visible — scheduleReposition's isRepositionPending guard
        // coalesces these to a SINGLE deferred reposition.
        for _ in 0..<6 {
            NotificationCenter.default.post(
                name: NSWindow.didResizeNotification, object: window)
        }
        drainMainRunloop(seconds: 0.3)

        let delta = FrameOriginCounter.shared.count - baseline
        // The coalescing guard bounds a burst to one in-flight pass. We don't assert an
        // exact count (initial layout may add one), but it must be SMALL — a pre-fix
        // synchronous loop would have re-entered unboundedly and crashed/exploded.
        XCTAssertLessThanOrEqual(delta, 2,
            "A resize burst while shown must coalesce to a small bounded number of "
            + "reposition calls (got \(delta)); the pre-fix loop recursed unboundedly.")
        XCTAssertGreaterThanOrEqual(delta, 1,
            "Observer must still re-anchor while shown (got \(delta)); if 0, the "
            + "observer-removed test above is green for the wrong reason.")
    }

    // MARK: - P0: setFrameOrigin deferred out of the layout pass (no synchronous re-entry)

    /// The #11 re-entrancy was `setFrameOrigin` called synchronously inside the layout
    /// pass that posted `didResizeNotification`. The fix dispatches reposition to the
    /// next runloop turn. Assert: when a didResizeNotification fires, the resulting
    /// setFrameOrigin does NOT happen within the same synchronous call frame — it happens
    /// on a later runloop iteration.
    func testSetFrameOriginDeferredOutOfLayoutPass() {
        let manager = IndicatorWindowManager.shared
        _ = manager.show(nearPoint: nil)
        guard let window = manager.window else {
            XCTFail("show() must install a window"); return
        }
        drainMainRunloop(seconds: 0.1)

        // Within the synchronous handling of the notification, setFrameOrigin must NOT
        // be called. We detect this by recording whether the count changed during the
        // post() call itself.
        let before = FrameOriginCounter.shared.count
        NotificationCenter.default.post(
            name: NSWindow.didResizeNotification, object: window)
        let synchronousDelta = FrameOriginCounter.shared.count - before

        XCTAssertEqual(synchronousDelta, 0,
            "setFrameOrigin must NOT run synchronously inside the didResizeNotification "
            + "handler (got \(synchronousDelta) synchronous call(s)); the fix defers it. "
            + "Synchronous frame mutation mid-layout is the #11 re-entrancy.")

        // And it DOES happen once we drain the deferred dispatch — proving the deferral,
        // not a no-op.
        drainMainRunloop(seconds: 0.3)
        let deferredDelta = FrameOriginCounter.shared.count - before
        XCTAssertGreaterThanOrEqual(deferredDelta, 1,
            "After draining the runloop, the deferred reposition must have run "
            + "(got \(deferredDelta) total); if 0, reposition was dropped entirely.")
    }

    // MARK: - P0: no runaway layout on the recording-stop transition (count-budget + timeout)

    /// Drives the literal crash path — caption growth then the recording-stop transition —
    /// and asserts no runaway layout: setFrameOrigin count stays under a small budget and
    /// the whole sequence completes within a wall-clock timeout. Pre-fix this path
    /// overflowed the stack at ~6,795 recursion levels; any sane budget is a clean signal.
    ///
    /// No microphone / permissions: caption growth is simulated by publishing streaming
    /// text, and the stop transition by flipping the view-model state.
    ///
    /// RESIDUAL — documented honestly (counter-test-by-revert, source-only revert of
    /// `eed859c`): this test PASSES both pre-fix and post-fix on this dev machine's macOS,
    /// because AppKit self-damps the synchronous re-entry to a bounded number of passes
    /// here. The unbounded runaway only manifests under macOS 26/Tahoe's altered layout
    /// timing (issue #11's trigger), which cannot be reproduced in this CI environment.
    /// So this test is a defense-in-depth belt — it would fire only if re-entry became
    /// unbounded on THIS OS too — NOT the primary regression anchor. The primary anchors
    /// are testObserverRemovedOnHide_NoFurtherReposition and
    /// testSetFrameOriginDeferredOutOfLayoutPass, which DO fail pre-fix. The macOS-26
    /// runaway itself is covered by the manual Tahoe smoke (per the plan's test matrix).
    func testNoRunawayLayoutOnRecordingStopTransition() {
        let manager = IndicatorWindowManager.shared
        let vm = manager.show(nearPoint: nil)

        // Simulate caption growth (the live-transcription path that grows bubbleWidth).
        let streaming = StreamingTranscriptionController.shared
        vm.state = .recording
        for i in 0..<8 {
            streaming._testInjectCaption(confirmed: String(repeating: "word ", count: (i + 1) * 3))
            drainMainRunloop(seconds: 0.05)
        }

        let baseline = FrameOriginCounter.shared.count

        // The stop-time settle storm: hide() flips isVisible spring + scaleEffect/opacity
        // + bubbleWidth collapse — three concurrent animated geometry changes that pre-fix
        // re-entered updateAnimatedWindowSize unboundedly. Wrap in a wall-clock timeout.
        let stopDeadline = Date(timeIntervalSinceNow: 5.0)
        manager.hide()

        // Pump the runloop until the hide Task + deferred repositions settle, or timeout.
        while Date() < stopDeadline {
            drainMainRunloop(seconds: 0.1)
            // Once the window is torn down (viewModel nilled), the storm is over.
            if manager.viewModel == nil && manager.window?.isVisible == false {
                break
            }
        }

        let totalDelta = FrameOriginCounter.shared.count - baseline

        // COUNT BUDGET: pre-fix recursion was ~6,795 deep. A bounded budget of 50 is a
        // 100x+ safety margin over any legitimate settle repositioning; if the loop were
        // still present we'd see thousands (or a process crash).
        XCTAssertLessThan(totalDelta, 50,
            "Recording-stop transition must not drive a runaway number of setFrameOrigin "
            + "calls (got \(totalDelta)); the pre-fix loop recursed ~6,795 times. "
            + "A count under 50 proves the re-entrancy is broken.")

        // WALL-CLOCK TIMEOUT: if we exited because the deadline passed (not because the
        // window tore down), the sequence did not settle — a near-infinite loop symptom.
        let settled = (manager.viewModel == nil)
        XCTAssertTrue(settled,
            "Recording-stop transition must settle (window torn down) within the timeout; "
            + "if it didn't, a layout loop is still running.")
    }

    // MARK: - P1: pill-growth preserved (window still resizes to fit growing content)

    /// `sizingOptions = [.preferredContentSize]` is RETAINED by the fix so the live-caption
    /// pill still grows. Assert that growing the hosted content changes the window's
    /// content size — i.e., auto-sizing was not removed wholesale.
    ///
    /// Counter-test-by-revert (source-only revert of `eed859c`): this test PASSES both
    /// pre-fix and post-fix — CORRECTLY, because the fix deliberately retains
    /// `.preferredContentSize` (growth is identical either way). This is a regression
    /// guard for a behavior the fix must NOT break, not a guard for the bug itself.
    func testPillGrowthPreserved_WindowResizesToFitContent() {
        let manager = IndicatorWindowManager.shared
        let vm = manager.show(nearPoint: nil)
        guard let window = manager.window else {
            XCTFail("show() must install a window"); return
        }
        vm.state = .recording
        drainMainRunloop(seconds: 0.2)

        let sizeBefore = window.contentView?.frame.size
            ?? NSSize(width: 0, height: 0)

        // Grow the caption substantially.
        let streaming = StreamingTranscriptionController.shared
        streaming._testInjectCaption(confirmed: String(repeating: "a growing caption ", count: 30))
        // Give the hosting controller's preferredContentSize + the deferred reposition
        // time to flow through.
        drainMainRunloop(seconds: 0.4)

        let sizeAfter = window.contentView?.frame.size
            ?? NSSize(width: 0, height: 0)

        // Width is the load-bearing growth dimension for the live caption (bubbleWidth).
        // We assert width OR height grew — the pill grows to fit its content. The exact
        // axis depends on layout, but a strictly-equal/zero-growth result would mean
        // auto-sizing was broken.
        let grew = (sizeAfter.width > sizeBefore.width + 1)
            || (sizeAfter.height > sizeBefore.height + 1)
        XCTAssertTrue(grew,
            "Pill-growth must be preserved: growing the hosted caption content must grow "
            + "the window content size. Before=\(sizeBefore), After=\(sizeAfter). "
            + "If neither axis grew, the fix broke auto-sizing.")
    }

    // MARK: - Helpers

    /// Pumps the main runloop so deferred `DispatchQueue.main.async` blocks
    /// (scheduleReposition) and hide()'s `Task` get a chance to execute.
    private func drainMainRunloop(seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: min(0.05, seconds)))
        }
    }
}

// MARK: - FrameOriginCounter (swizzle on NSWindow.setFrameOrigin)

/// Counts `NSWindow.setFrameOrigin(_:)` invocations process-wide via a one-shot
/// `dispatch_once`-style swizzle. This is the observable seam for "setFrameOrigin never
/// runs inside the in-flight layout pass": a synchronous call inside a didResizeNotification
/// handler increments the counter in the same call frame; a deferred call increments it on
/// a later runloop turn.
///
/// Swizzling `setFrameOrigin` (not `updateAnimatedWindowSize`) is deliberate: setFrameOrigin
/// is OUR reposition's terminal call and is a public AppKit API safe to swizzle, whereas
/// `updateAnimatedWindowSize` is private SwiftUI and the fix specifically keeps it working
/// (pill-growth depends on it). We assert on the observable consequence (frame origin
/// mutation timing), not on SwiftUI internals.
final class FrameOriginCounter {
    static let shared = FrameOriginCounter()
    private(set) var count = 0

    private static var installed = false
    private static let installLock = NSLock()

    static func installIfNeeded() {
        installLock.lock(); defer { installLock.unlock() }
        guard !installed else { return }
        installed = true

        let cls: AnyClass = NSWindow.self
        let original = class_getInstanceMethod(cls, #selector(NSWindow.setFrameOrigin(_:)))
        let swizzled = class_getInstanceMethod(cls, #selector(NSWindow.osw_setFrameOrigin(_:)))
        guard let original, let swizzled else { return }
        method_exchangeImplementations(original, swizzled)
    }

    func reset() { count = 0 }
    fileprivate func tick() { count += 1 }
}

private extension NSWindow {
    @objc func osw_setFrameOrigin(_ point: NSPoint) {
        FrameOriginCounter.shared.tick()
        // Call the original (implementations are exchanged, so this is the original).
        self.osw_setFrameOrigin(point)
    }
}
