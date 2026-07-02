import XCTest
@testable import OpenSuperWhisper

/// Per-app / per-site model rules resolve with **site-beats-app** precedence: a
/// rule bound to a specific website (`bundleID|host`) wins over the app-wide rule
/// (`bundleID`), which wins over nothing. The composite key encodes that. This
/// guards the key format and the resolution order so dictating on a ruled site
/// picks the intended model, and removing a site rule falls back to the app rule.
final class AppContextModelRulesTests: XCTestCase {

    private var savedRules: Data!

    override func setUp() {
        super.setUp()
        savedRules = AppPreferences.shared.appModelRulesData
        AppPreferences.shared.appModelRulesData = Data()  // start from a clean store
    }

    override func tearDown() {
        AppPreferences.shared.appModelRulesData = savedRules
        super.tearDown()
    }

    private func model(_ id: String) -> DictationModelOption {
        DictationModelOption(engine: "remote", identifier: id, displayName: id)
    }

    // MARK: - Key format

    func testKeyIsBundleIDAloneForAppRule() {
        XCTAssertEqual(AppContextModelRules.key(bundleID: "com.apple.Safari", host: nil), "com.apple.Safari")
        XCTAssertEqual(AppContextModelRules.key(bundleID: "com.apple.Safari", host: ""), "com.apple.Safari")
    }

    func testKeyIsCompositeForSiteRule() {
        XCTAssertEqual(AppContextModelRules.key(bundleID: "com.google.Chrome", host: "github.com"),
                       "com.google.Chrome|github.com")
    }

    // MARK: - Resolution precedence

    func testSiteRuleWinsOverAppRule() {
        AppContextModelRules.set(model("app-model"), for: "com.google.Chrome")
        AppContextModelRules.set(model("site-model"), for: "com.google.Chrome", host: "github.com")

        // On the ruled site → the site model.
        XCTAssertEqual(AppContextModelRules.rule(for: "com.google.Chrome", host: "github.com")?.identifier,
                       "site-model")
        // On a different (unruled) site in the same app → app fallback.
        XCTAssertEqual(AppContextModelRules.rule(for: "com.google.Chrome", host: "example.com")?.identifier,
                       "app-model")
        // No site context → app rule.
        XCTAssertEqual(AppContextModelRules.rule(for: "com.google.Chrome", host: nil)?.identifier,
                       "app-model")
    }

    func testNoRuleReturnsNil() {
        XCTAssertNil(AppContextModelRules.rule(for: "com.unknown.App", host: nil))
        XCTAssertNil(AppContextModelRules.rule(for: "com.unknown.App", host: "example.com"))
    }

    func testRemoveDeletesExactScopeAndFallsBack() {
        AppContextModelRules.set(model("app-model"), for: "com.google.Chrome")
        AppContextModelRules.set(model("site-model"), for: "com.google.Chrome", host: "github.com")
        AppContextModelRules.remove(bundleID: "com.google.Chrome", host: "github.com")

        // The exact site scope is gone; resolution falls back to the still-present app rule.
        XCTAssertNil(AppContextModelRules.exactRule(for: "com.google.Chrome", host: "github.com"))
        XCTAssertEqual(AppContextModelRules.rule(for: "com.google.Chrome", host: "github.com")?.identifier,
                       "app-model")
    }
}
