import XCTest

@testable import OpenSuperWhisper

/// Telling a measurement from a preference.
///
/// Reported after a change of Mac: the notch pill was hidden behind the physical notch. The
/// geometry was never read — `NotchMetrics` computed it correctly and nothing consumed it, so a
/// 42pt pill hung from the top of a screen whose top 38pt are a hole.
final class NotchMetricsTests: XCTestCase {

    /// Measured on the reporter's machine: a 2056pt-wide built-in display with 918pt of usable
    /// menu bar on each side, and a 38pt safe-area inset.
    private let screenWidth: CGFloat = 2056
    private let auxSide: CGFloat = 918

    private func notchWidth(screenWidth: CGFloat, left: CGFloat, right: CGFloat) -> CGFloat {
        screenWidth - left - right + NotchMetrics.edgeAllowance
    }

    func testTheCutoutIsWiderThanItsGeometryByTheEdgeAllowance() {
        let width = notchWidth(screenWidth: screenWidth, left: auxSide, right: auxSide)

        XCTAssertEqual(width, 224, accuracy: 0.001, "220pt of hardware plus the soft-edge cover")
    }

    /// Matching the cutout exactly leaves a hairline of wallpaper down each side, because it is
    /// not a clean rectangle. Small, non-zero, and the same figure boring.notch settled on.
    func testTheEdgeAllowanceIsASliverAndNotAGuess() {
        XCTAssertGreaterThan(NotchMetrics.edgeAllowance, 0)
        XCTAssertLessThanOrEqual(NotchMetrics.edgeAllowance, 8)
    }

    /// An off-centre notch would still be measured correctly: the width comes from both sides,
    /// not from doubling one of them.
    func testAnUnevenlySplitMenuBarStillMeasures() {
        let width = notchWidth(screenWidth: 2056, left: 900, right: 936)

        XCTAssertEqual(width, 224, accuracy: 0.001)
    }

    // MARK: - The distinction that was missing

    /// Every real screen answers this; the point is that the type can say "none", which is what
    /// the drawing code needs in order to stop treating a preference as a fitting.
    func testAScreenWithoutACutoutReportsNoneRatherThanAStandIn() {
        for screen in NSScreen.screens where screen.safeAreaInsets.top == 0 {
            XCTAssertNil(NotchMetrics.physicalNotch(for: screen),
                         "\(screen.localizedName) has no cutout and must not report a size")
            XCTAssertFalse(NotchMetrics.hasNotch(screen))
        }
    }

    /// On a machine that has one, the reported height is the safe-area inset exactly: it is the
    /// band the window may not draw into, and rounding it would put content back under hardware.
    func testACutoutReportsTheSafeAreaInsetExactly() throws {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        try XCTSkipIf(notched == nil, "no notched display attached")
        let screen = try XCTUnwrap(notched)
        let size = try XCTUnwrap(NotchMetrics.physicalNotch(for: screen))

        XCTAssertEqual(size.height, screen.safeAreaInsets.top, accuracy: 0.001)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertLessThan(size.width, screen.frame.width, "a cutout is narrower than its screen")
    }
}
