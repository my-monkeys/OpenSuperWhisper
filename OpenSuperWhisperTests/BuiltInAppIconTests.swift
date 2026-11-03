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
