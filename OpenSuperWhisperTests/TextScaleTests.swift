import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// Text sizes are multiplied by what macOS asks for and by what the user asked for on top.
/// Both contributions matter: the app used to ignore the system entirely, which is why its
/// settings window was unreadable for someone who had already made text bigger everywhere
/// else (#80).
final class TextScaleTests: XCTestCase {

    func testUntouchedSystemAndAppLeaveSizesAlone() {
        XCTAssertEqual(TextScale.resolve(11, appScale: TextScale.default, system: .large), 11,
                       accuracy: 0.001)
    }

    /// The point of the default: a user who set a larger text size in macOS gets it here too,
    /// without configuring anything in this app.
    func testSystemSettingAloneEnlarges() {
        let resolved = TextScale.resolve(11, appScale: TextScale.default, system: .accessibility1)
        XCTAssertGreaterThan(resolved, 11)
    }

    func testBothContributionsCompound() {
        let systemOnly = TextScale.resolve(10, appScale: 1.0, system: .xLarge)
        let both = TextScale.resolve(10, appScale: 1.3, system: .xLarge)
        XCTAssertGreaterThan(both, systemOnly)
    }

    func testLargerSystemSizesNeverShrinkText() {
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge,
                                        .xxxLarge, .accessibility1, .accessibility5]
        for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
            XCTAssertLessThanOrEqual(TextScale.resolve(12, appScale: 1, system: smaller),
                                     TextScale.resolve(12, appScale: 1, system: larger),
                                     "\(larger) must not render smaller than \(smaller)")
        }
    }

    /// Bounds exist because the layout does: key caps stop fitting their glyphs below the
    /// minimum, and the recording bubble outgrows a comfortable overlay above the maximum.
    func testAppScaleIsClamped() {
        XCTAssertEqual(TextScale.clamped(0.1), TextScale.minimum)
        XCTAssertEqual(TextScale.clamped(99), TextScale.maximum)
        XCTAssertEqual(TextScale.clamped(1.2), 1.2)
    }

    func testOutOfRangeStoredValueCannotBreakLayout() {
        let tiny = TextScale.resolve(11, appScale: -5, system: .large)
        let huge = TextScale.resolve(11, appScale: 100, system: .large)
        XCTAssertEqual(tiny, 11 * CGFloat(TextScale.minimum), accuracy: 0.001)
        XCTAssertEqual(huge, 11 * CGFloat(TextScale.maximum), accuracy: 0.001)
    }
}
