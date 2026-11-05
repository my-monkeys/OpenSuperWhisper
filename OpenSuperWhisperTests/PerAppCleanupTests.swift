import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// AI cleanup and the writing style per app and per site: the key format, the order the lookups
/// resolve in, the rows built from those keys and what the page's store does with them.
final class PerAppCleanupTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared
    private var savedRules: Data!
    private let dia = "company.thebrowser.dia"

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences()
        savedRules = prefs.appModelRulesData
        prefs.appModelRulesData = Data()
    }

    override func tearDown() {
        prefs.appModelRulesData = savedRules
        scratch.restore()
        super.tearDown()
    }

    private func model(_ id: String) -> DictationModelOption {
        DictationModelOption(engine: "remote", identifier: id, displayName: id)
    }

    // MARK: - Keys

    func testAnAppKeyIsLowercasedAndASiteKeyAddsItsHost() {
        XCTAssertEqual(PerAppOverride.key(bundleID: "company.thebrowser.Dia", host: nil), dia)
        XCTAssertEqual(PerAppOverride.key(bundleID: "company.thebrowser.Dia", host: "Mail.Google.com"),
                       "\(dia)|mail.google.com")
        XCTAssertEqual(PerAppOverride.key(bundleID: dia, host: ""), dia)
    }

    func testHostsAreNormalisedFromWhateverWasTyped() {
        XCTAssertEqual(SourceCapture.normalizedHost("mail.google.com"), "mail.google.com")
        XCTAssertEqual(SourceCapture.normalizedHost("  Mail.Google.COM "), "mail.google.com")
        XCTAssertEqual(SourceCapture.normalizedHost("https://www.mail.google.com/mail/u/0/#inbox"), "mail.google.com")
        XCTAssertEqual(SourceCapture.normalizedHost("http://github.com:8080/a?b=c"), "github.com")
        XCTAssertEqual(SourceCapture.normalizedHost("www.github.com/x"), "github.com")
        XCTAssertNil(SourceCapture.normalizedHost(""))
        XCTAssertNil(SourceCapture.normalizedHost("   "))
        XCTAssertNil(SourceCapture.normalizedHost("not a host"))
    }

    func testDiaIsASupportedBrowserWhateverTheCase() {
        XCTAssertTrue(SourceCapture.isSupportedBrowser(bundleID: "company.thebrowser.Dia"))
        XCTAssertTrue(SourceCapture.isSupportedBrowser(bundleID: "com.apple.Safari"))
        XCTAssertFalse(SourceCapture.isSupportedBrowser(bundleID: "com.apple.Notes"))
    }

    // MARK: - Resolution

    func testNoOverrideFollowsTheGlobalSwitch() {
        prefs.aiPostProcessingEnabled = false
        XCTAssertFalse(prefs.cleanupEnabled(bundleID: "com.apple.notes"))
        prefs.aiPostProcessingEnabled = true
        XCTAssertTrue(prefs.cleanupEnabled(bundleID: "com.apple.notes"))
        XCTAssertTrue(prefs.cleanupEnabled(bundleID: nil))
    }

    func testAnAppValueBeatsTheGlobalSwitchEitherWay() {
        prefs.appCleanupOverrides = ["com.apple.notes": true, "com.apple.mail": false]
        prefs.aiPostProcessingEnabled = false
        XCTAssertTrue(prefs.cleanupEnabled(bundleID: "com.apple.Notes"))
        prefs.aiPostProcessingEnabled = true
        XCTAssertFalse(prefs.cleanupEnabled(bundleID: "com.apple.Mail"))
    }

    func testASiteValueBeatsTheAppsAndAnotherSiteFallsBackToTheApp() {
        prefs.aiPostProcessingEnabled = false
        prefs.appCleanupOverrides = ["\(dia)|mail.google.com": true, dia: false]
        XCTAssertTrue(prefs.cleanupEnabled(bundleID: dia, host: "mail.google.com"))
        XCTAssertFalse(prefs.cleanupEnabled(bundleID: dia, host: "github.com"))
        XCTAssertFalse(prefs.cleanupEnabled(bundleID: dia, host: nil))
    }

    func testASiteAloneLeavesTheRestOfTheBrowserOnTheGlobalSwitch() {
        prefs.aiPostProcessingEnabled = false
        prefs.appCleanupOverrides = ["\(dia)|mail.google.com": true]
        XCTAssertTrue(prefs.cleanupEnabled(bundleID: dia, host: "mail.google.com"))
        XCTAssertFalse(prefs.cleanupEnabled(bundleID: dia, host: "github.com"))
    }

    func testASwitchedOffAppGetsTheGlobalValuesSiteOverridesIncluded() {
        prefs.aiPostProcessingEnabled = false
        prefs.appCleanupOverrides = ["\(dia)|mail.google.com": true, dia: true]
        prefs.perAppDisabledBundleIDs = [dia]
        XCTAssertFalse(prefs.cleanupEnabled(bundleID: dia, host: "mail.google.com"))
        XCTAssertFalse(prefs.cleanupEnabled(bundleID: dia))
        prefs.aiPostProcessingEnabled = true
        prefs.appCleanupOverrides = [dia: false]
        XCTAssertTrue(prefs.cleanupEnabled(bundleID: dia))
    }

    func testTheStyleResolvesSiteThenAppThenDefault() {
        prefs.writingStyleID = WritingStyle.personalID
        prefs.appWritingStyles = [dia: WritingStyle.proID, "\(dia)|mail.google.com": WritingStyle.rawID]
        XCTAssertEqual(prefs.writingStyle(for: dia, host: "mail.google.com"), .raw)
        XCTAssertEqual(prefs.writingStyle(for: dia, host: "github.com"), .pro)
        XCTAssertEqual(prefs.writingStyle(for: dia).id, WritingStyle.proID)
        XCTAssertEqual(prefs.writingStyle(for: "com.apple.notes", host: "x.com").id, WritingStyle.personalID)
    }

    func testASwitchedOffAppKeepsTheDefaultStyleOnItsSites() {
        prefs.writingStyleID = WritingStyle.personalID
        prefs.appWritingStyles = ["\(dia)|mail.google.com": WritingStyle.proID]
        prefs.perAppDisabledBundleIDs = [dia]
        XCTAssertEqual(prefs.writingStyle(for: dia, host: "mail.google.com").id, WritingStyle.personalID)
    }

    // MARK: - Rows

    private func build(styles: [String: String] = [:], cleanups: [String: Bool] = [:],
                       modelRules: [String: DictationModelOption] = [:],
                       pendingSites: [PerAppEntries.PendingSite] = []) -> [PerAppEntry] {
        PerAppEntries.build(insertionRules: [], profiles: [], modelRules: modelRules, styles: styles,
                            cleanups: cleanups, pending: [], pendingSites: pendingSites)
    }

    func testCleanupAndStyleKeysBuildAppRowsAndSiteRows() {
        let rows = build(styles: ["\(dia)|mail.google.com": "pro"],
                         cleanups: ["com.apple.notes": true, "\(dia)|mail.google.com": true])

        // Rows sort by the installed app's name, which depends on this Mac: look them up by id.
        XCTAssertEqual(Set(rows.map(\.id)), ["com.apple.notes", "\(dia)|mail.google.com"])
        let app = rows.first { $0.id == "com.apple.notes" }
        let site = rows.first { $0.isSite }
        XCTAssertEqual(app?.cleanup, true)
        XCTAssertEqual(site?.host, "mail.google.com")
        XCTAssertEqual(site?.style, "pro")
        XCTAssertEqual(site?.cleanup, true)
    }

    func testAModelRuleAndTheSiteKeysMergeIntoOneSiteRow() {
        let rows = build(styles: ["\(dia)|github.com": "pro"],
                         cleanups: ["\(dia)|GitHub.com": false],
                         modelRules: ["company.thebrowser.Dia|github.com": model("Turbo")])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].model, model("Turbo"))
        XCTAssertEqual(rows[0].style, "pro")
        XCTAssertEqual(rows[0].cleanup, false)
    }

    func testASiteRowFollowsItsAppRow() {
        let rows = build(cleanups: [dia: false, "\(dia)|mail.google.com": true])
        XCTAssertEqual(rows.map(\.isSite), [false, true])
    }

    func testAPendingSiteIsARowThatIsDroppedOnceSomethingIsSetForIt() {
        let pending = PerAppEntries.PendingSite(bundleID: dia, host: "mail.google.com")
        let rows = build(pendingSites: [pending])
        XCTAssertEqual(rows.map(\.id), ["\(dia)|mail.google.com"])
        XCTAssertTrue(rows[0].isEmpty)

        let set = build(cleanups: ["\(dia)|mail.google.com": true], pendingSites: [pending])
        XCTAssertEqual(set.count, 1)
        XCTAssertEqual(set[0].cleanup, true)
    }

    func testCleanupAndStyleBadgesShowOnlyWhenSet() {
        let site = PerAppEntry(bundleID: dia, host: "mail.google.com", appName: "Dia", style: "pro", cleanup: true)
        XCTAssertEqual(PerAppBadge.badges(for: site, styleName: "Pro"), [.style("Pro"), .cleanup(true)])
        let off = PerAppEntry(bundleID: dia, host: nil, appName: "Dia", cleanup: false)
        XCTAssertEqual(PerAppBadge.badges(for: off, styleName: nil), [.cleanup(false)])
        let none = PerAppEntry(bundleID: dia, host: nil, appName: "Dia")
        XCTAssertEqual(PerAppBadge.badges(for: none, styleName: nil), [.standard])
    }

    // MARK: - Store

    @MainActor
    func testSettingAndClearingCleanupAndStyleWritesTheSiteKey() {
        let viewModel = SettingsViewModel()
        let store = PerAppStore(viewModel: viewModel)
        let site = PerAppEntry(bundleID: "company.thebrowser.Dia", host: "mail.google.com", appName: "Dia")

        store.setCleanup(true, for: site)
        store.setStyle("pro", for: site)
        XCTAssertEqual(prefs.appCleanupOverrides, ["\(dia)|mail.google.com": true])
        XCTAssertEqual(prefs.appWritingStyles, ["\(dia)|mail.google.com": "pro"])

        store.setCleanup(nil, for: site)
        store.setStyle(nil, for: site)
        XCTAssertEqual(prefs.appCleanupOverrides, [:])
        XCTAssertEqual(prefs.appWritingStyles, [:])
    }

    @MainActor
    func testRemovingASiteRowDropsItsModelStyleAndCleanupButNotTheApps() {
        let viewModel = SettingsViewModel()
        let store = PerAppStore(viewModel: viewModel)
        viewModel.appCleanupOverrides = [dia: false, "\(dia)|mail.google.com": true]
        viewModel.appWritingStyles = [dia: "raw", "\(dia)|mail.google.com": "pro"]
        AppContextModelRules.set(model("Turbo"), for: "company.thebrowser.dia", host: "mail.google.com")
        AppContextModelRules.set(model("Parakeet"), for: "company.thebrowser.dia")

        let site = build(styles: viewModel.appWritingStyles, cleanups: viewModel.appCleanupOverrides,
                         modelRules: AppContextModelRules.all()).first { $0.isSite }!
        store.remove(site)

        XCTAssertEqual(prefs.appCleanupOverrides, [dia: false])
        XCTAssertEqual(prefs.appWritingStyles, [dia: "raw"])
        XCTAssertEqual(Array(AppContextModelRules.all().keys), ["company.thebrowser.dia"])
    }

    @MainActor
    func testRemovingAnAppRowKeepsItsSiteKeys() {
        let viewModel = SettingsViewModel()
        let store = PerAppStore(viewModel: viewModel)
        viewModel.appCleanupOverrides = [dia: false, "\(dia)|mail.google.com": true]
        viewModel.appWritingStyles = [dia: "raw", "\(dia)|mail.google.com": "pro"]

        store.remove(PerAppEntry(bundleID: dia, host: nil, appName: "Dia", style: "raw", cleanup: false))

        XCTAssertEqual(prefs.appCleanupOverrides, ["\(dia)|mail.google.com": true])
        XCTAssertEqual(prefs.appWritingStyles, ["\(dia)|mail.google.com": "pro"])
    }

    @MainActor
    func testChangingTheAppMovesItsStyleAndCleanup() {
        let viewModel = SettingsViewModel()
        let store = PerAppStore(viewModel: viewModel)
        viewModel.appCleanupOverrides = ["com.apple.notes": true]
        viewModel.appWritingStyles = ["com.apple.notes": "pro"]

        store.reassign(PerAppEntry(bundleID: "com.apple.notes", host: nil, appName: "Notes",
                                   style: "pro", cleanup: true),
                       to: InstalledApp(bundleIdentifier: "net.shinyfrog.bear", name: "Bear", url: URL(fileURLWithPath: "/")))

        XCTAssertEqual(prefs.appCleanupOverrides, ["net.shinyfrog.bear": true])
        XCTAssertEqual(prefs.appWritingStyles, ["net.shinyfrog.bear": "pro"])
    }
}
