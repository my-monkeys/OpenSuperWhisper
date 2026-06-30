import XCTest
import SwiftUI
@testable import OpenSuperWhisper

/// Guards the fix for the indicator-window layout-recursion crash (#11, #15, #19).
///
/// On macOS 26 (Tahoe), hosting the recording indicator with
/// `NSHostingController.sizingOptions = [.preferredContentSize]` makes NSHostingView auto-resize
/// the window to fit its content — and that resize runs *animated* whenever any SwiftUI animation
/// transaction is active during a layout pass (`NSHostingView.updateAnimatedWindowSize`), which
/// re-enters layout and recurses until the main-thread stack overflows (~6,795 frames → SIGSEGV).
///
/// The robust fix takes window sizing off SwiftUI's animated path entirely: the window is sized
/// manually, non-animated, via `IndicatorWindowManager.resizeToContent`, so `updateAnimatedWindowSize`
/// can never be invoked. This test pins the one invariant that makes that true — the hosting
/// controller must NOT be configured to auto-resize the window.
///
/// Counter-test: set `hostingSizingOptions` back to `[.preferredContentSize]` and these fail —
/// i.e. they fail exactly when the crash would return. (Regression-test idea from @michael-wojcik's
/// PR #13, adapted to the manual-sizing approach.)
final class IndicatorLayoutRecursionTests: XCTestCase {

    func testHostingDoesNotAutoResizeWindow() {
        // `.preferredContentSize` is the option that drives the animated window resize; its presence
        // is the crash. The window is sized by hand instead, so it must be absent.
        XCTAssertFalse(
            IndicatorWindowManager.hostingSizingOptions.contains(.preferredContentSize),
            "Indicator hosting must not use .preferredContentSize — it re-arms the macOS 26 layout-recursion crash (#11/#15/#19)."
        )
    }

    func testHostingSizingIsManual() {
        // No sizing option at all: NSHostingView neither resizes the window nor imposes intrinsic
        // bounds; `resizeToContent` owns the size.
        XCTAssertTrue(
            IndicatorWindowManager.hostingSizingOptions.isEmpty,
            "Indicator hosting sizingOptions must be empty — the window is sized manually via resizeToContent."
        )
    }
}
