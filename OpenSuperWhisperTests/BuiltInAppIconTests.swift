import AppKit
import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// A built-in profile shows its app's icon even on a Mac without the app (#272): every preset has
/// one in the asset catalog, named after the lowercased bundle identifier.
final class BuiltInAppIconTests: XCTestCase {

    func testEveryBuiltInProfileHasABundledIcon() {
        for preset in AppContextProfile.defaultPresets {
            let icon = InstalledApps.bundledIcon(forBundleIdentifier: preset.bundleIdentifier)
            XCTAssertNotNil(icon, "no icon in Assets.xcassets/AppIcons for \(preset.bundleIdentifier)")
        }
    }

    /// The four rows that showed no icon (#283 follow-up) were seeded terminals this Mac does not
    /// have, none of which had a bundled one.
    func testEverySeededTerminalHasABundledIcon() {
        for rule in AppInsertionRule.bundledTerminalPresets {
            XCTAssertNotNil(InstalledApps.bundledIcon(forBundleIdentifier: rule.bundleIdentifier),
                            "no icon in Assets.xcassets/AppIcons for \(rule.bundleIdentifier)")
        }
    }

    func testAnInstalledAppIsFoundWhateverTheCaseOfItsStoredIdentifier() {
        let id = "com.apple.Terminal"
        guard InstalledApps.isInstalled(bundleIdentifier: id) else { return }
        XCTAssertEqual(InstalledApps.applicationURL(forBundleIdentifier: id.lowercased()),
                       InstalledApps.applicationURL(forBundleIdentifier: id))
        XCTAssertTrue(InstalledApps.isInstalled(bundleIdentifier: id.uppercased()))
    }

    func testAnAppWithoutABuiltInProfileHasNoBundledIcon() {
        XCTAssertNil(InstalledApps.bundledIcon(forBundleIdentifier: "com.example.unknown"))
    }

    func testAnAppThatIsNotThereFallsBackToItsBundledIcon() {
        let id = "net.whatsapp.WhatsApp"
        guard !InstalledApps.isInstalled(bundleIdentifier: id) else { return }
        let icon = InstalledApps.icon(forBundleIdentifier: id)
        XCTAssertEqual(icon.tiffRepresentation, InstalledApps.bundledIcon(forBundleIdentifier: id)?.tiffRepresentation)
    }
}
