import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The per-app on/off switch: one list of switched-off apps that the four lookups (formatting
/// profile, insertion rule, model rule, writing style) all consult, which built-in profiles start
/// off, and what a row shows as badges.
final class PerAppSwitchTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared
    private var savedRules: Data!

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

    // MARK: - The helper

    func testAnAppIsOnUnlessListed() {
        XCTAssertTrue(PerAppSwitch.isOn("com.apple.mail", disabled: []))
        XCTAssertFalse(PerAppSwitch.isOn("com.apple.mail", disabled: ["com.apple.mail"]))
        XCTAssertTrue(PerAppSwitch.isOn("com.apple.notes", disabled: ["com.apple.mail"]))
    }

    func testTheCaseOfTheIdentifierDoesNotMatter() {
        XCTAssertFalse(PerAppSwitch.isOn("com.apple.Terminal", disabled: ["com.apple.terminal"]))
        XCTAssertFalse(PerAppSwitch.isOn("COM.APPLE.TERMINAL", disabled: ["com.apple.Terminal"]))
    }

    func testNoAppIsNeverOff() {
        XCTAssertTrue(PerAppSwitch.isOn(nil, disabled: [""]))
        XCTAssertTrue(PerAppSwitch.isOn("", disabled: [""]))
    }

    func testSettingStoresOneLowercasedEntryPerApp() {
        var list = PerAppSwitch.setting("com.apple.Mail", on: false, in: [])
        list = PerAppSwitch.setting("COM.APPLE.MAIL", on: false, in: list)
        XCTAssertEqual(list, ["com.apple.mail"])
        XCTAssertEqual(PerAppSwitch.setting("com.Apple.mail", on: true, in: list), [])
    }

    // MARK: - The four lookups

    func testAnInsertionRuleIsIgnoredWhileTheAppIsOff() {
        let rule = AppInsertionRule(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", mode: .paste)
        XCTAssertEqual(AppInsertionRule.rule(for: "com.apple.Terminal", in: [rule], disabled: []), rule)
        XCTAssertNil(AppInsertionRule.rule(for: "com.apple.Terminal", in: [rule], disabled: ["com.apple.terminal"]))
        XCTAssertEqual(AppInsertionRule.rule(for: "com.apple.Terminal", in: [rule],
                                             disabled: ["com.apple.mail"]), rule)
    }

    func testAModelRuleIsIgnoredWhileTheAppIsOffSiteRulesIncluded() {
        AppContextModelRules.set(model("app"), for: "com.apple.Safari")
        AppContextModelRules.set(model("site"), for: "com.apple.Safari", host: "github.com")
        XCTAssertEqual(AppContextModelRules.rule(for: "com.apple.Safari", host: "github.com"), model("site"))

        prefs.perAppDisabledBundleIDs = ["com.apple.safari"]

        XCTAssertNil(AppContextModelRules.rule(for: "com.apple.Safari"))
        XCTAssertNil(AppContextModelRules.rule(for: "com.apple.Safari", host: "github.com"))
        XCTAssertEqual(AppContextModelRules.exactRule(for: "com.apple.Safari", host: nil), model("app"),
                       "switching off keeps the rule stored")
    }

    func testAWritingStyleIsIgnoredWhileTheAppIsOff() {
        prefs.writingStyleID = WritingStyle.proID
        prefs.appWritingStyles = ["com.apple.mail": WritingStyle.personalID]
        XCTAssertEqual(prefs.writingStyle(for: "com.apple.Mail").id, WritingStyle.personalID)

        prefs.perAppDisabledBundleIDs = ["com.apple.mail"]

        XCTAssertEqual(prefs.writingStyle(for: "com.apple.Mail"), .pro)
        XCTAssertEqual(prefs.appWritingStyles["com.apple.mail"], WritingStyle.personalID)
    }

    // MARK: - What starts off

    func testAFreshInstallHasEveryBuiltInProfileOffExceptTheTerminalWithAPasteRule() {
        prefs.runMigrations()

        let expectedOn = ["com.apple.Terminal"]
        for preset in AppContextProfile.defaultPresets {
            XCTAssertEqual(PerAppSwitch.isOn(preset.bundleIdentifier, disabled: prefs.perAppDisabledBundleIDs),
                           expectedOn.contains(preset.bundleIdentifier), preset.bundleIdentifier)
        }
        XCTAssertTrue(PerAppSwitch.isOn("com.apple.Terminal", disabled: prefs.perAppDisabledBundleIDs),
                      "the seeded paste rule keeps working")
        XCTAssertEqual(prefs.appInsertionRules.map(\.bundleIdentifier),
                       AppInsertionRule.bundledTerminalPresets.map(\.bundleIdentifier))
    }

    func testAnExistingInstallKeepsSlackAndTerminalAndGetsTheNewPresetsOff() {
        prefs.appContextProfiles = AppContextProfile.firstShippedPresets
        prefs.didSeedAppContextPresets = true

        prefs.runMigrations()

        XCTAssertTrue(PerAppSwitch.isOn("com.tinyspeck.slackmacgap", disabled: prefs.perAppDisabledBundleIDs))
        XCTAssertTrue(PerAppSwitch.isOn("com.apple.Terminal", disabled: prefs.perAppDisabledBundleIDs))
        let added = AppContextProfile.defaultPresets.dropFirst(2)
        XCTAssertFalse(added.isEmpty)
        for preset in added {
            XCTAssertFalse(PerAppSwitch.isOn(preset.bundleIdentifier, disabled: prefs.perAppDisabledBundleIDs),
                           preset.bundleIdentifier)
        }
    }

    func testAnInstallThatAlreadyHadEveryPresetKeepsThemOn() {
        prefs.appContextProfiles = AppContextProfile.defaultPresets
        prefs.didSeedAppContextPresets = true
        prefs.offeredAppContextPresets = AppContextProfile.defaultPresets.map(\.bundleIdentifier)

        prefs.runMigrations()

        XCTAssertEqual(prefs.perAppDisabledBundleIDs, [])
    }

    func testAUsersOwnProfileForAnAppIsNotSwitchedOff() {
        let own = AppContextProfile(bundleIdentifier: "com.apple.notes", appName: "Notes", instructions: "mine")
        prefs.appContextProfiles = AppContextProfile.firstShippedPresets + [own]
        prefs.didSeedAppContextPresets = true

        prefs.runMigrations()

        XCTAssertTrue(PerAppSwitch.isOn("com.apple.Notes", disabled: prefs.perAppDisabledBundleIDs))
    }

    func testUserProfilesOnAFreshInstallLeaveTheListEmpty() {
        prefs.appContextProfiles = [AppContextProfile(bundleIdentifier: "com.example.editor", instructions: "x")]

        prefs.runMigrations()

        XCTAssertEqual(prefs.perAppDisabledBundleIDs, [])
    }

    // MARK: - Badges

    private func entry(insertion: AppInsertionRule? = nil, instructions: String? = nil,
                       model: DictationModelOption? = nil, style: String? = nil,
                       host: String? = nil) -> PerAppEntry {
        PerAppEntry(bundleID: "com.example.app", host: host, appName: "App", insertion: insertion,
                    profiles: instructions.map { [AppContextProfile(bundleIdentifier: "com.example.app",
                                                                   instructions: $0)] } ?? [],
                    model: model, style: style)
    }

    func testARowWithNothingCustomisedShowsOnlyDefault() {
        XCTAssertEqual(PerAppBadge.badges(for: entry(), styleName: nil), [.standard])
    }

    func testABlankProfileIsNotFormattingRules() {
        XCTAssertEqual(PerAppBadge.badges(for: entry(instructions: " \n"), styleName: nil), [.standard])
    }

    func testEachCustomisationGetsABadgeInOrder() {
        let typed = AppInsertionRule(bundleIdentifier: "com.example.app", mode: .type, typingPaceMilliseconds: 4)
        let badges = PerAppBadge.badges(
            for: entry(insertion: typed, instructions: "x", model: model("Parakeet v3"), style: "pro"),
            styleName: "Pro")

        XCTAssertEqual(badges, [.style("Pro"), .insertion(.type, paceMilliseconds: 4),
                                .model("Parakeet v3"), .formatting])
    }

    func testPasteHasNoPace() {
        let paste = AppInsertionRule(bundleIdentifier: "com.example.app", mode: .paste)
        XCTAssertEqual(PerAppBadge.badges(for: entry(insertion: paste), styleName: nil),
                       [.insertion(.paste, paceMilliseconds: nil)])
    }

    func testASiteRowOnlyShowsItsModel() {
        XCTAssertEqual(PerAppBadge.badges(for: entry(model: model("Turbo"), host: "github.com"), styleName: nil),
                       [.model("Turbo")])
    }
}
