import XCTest
@testable import OpenSuperWhisper

/// `AppContextRuleRow.parse` is the inverse of `AppContextModelRules.key`: the
/// latter builds a stored rule key (`bundleID` or `bundleID|host`), the former
/// splits it back into (bundleID, host) for display. This guards that the
/// composite format round-trips, so the App Context list shows the right app/site
/// for each stored rule.
final class AppContextRuleKeyTests: XCTestCase {

    func testParsesAppOnlyKey() {
        let parsed = AppContextRuleRow.parse("com.apple.Safari")
        XCTAssertEqual(parsed.bundleID, "com.apple.Safari")
        XCTAssertNil(parsed.host)
    }

    func testParsesCompositeSiteKey() {
        let parsed = AppContextRuleRow.parse("com.google.Chrome|github.com")
        XCTAssertEqual(parsed.bundleID, "com.google.Chrome")
        XCTAssertEqual(parsed.host, "github.com")
    }

    func testRoundTripsWithKeyBuilder() {
        let cases: [(bundle: String, host: String?)] = [
            ("com.apple.Safari", nil),
            ("com.google.Chrome", "docs.google.com"),
        ]
        for c in cases {
            let key = AppContextModelRules.key(bundleID: c.bundle, host: c.host)
            let parsed = AppContextRuleRow.parse(key)
            XCTAssertEqual(parsed.bundleID, c.bundle)
            XCTAssertEqual(parsed.host, c.host)
        }
    }
}
