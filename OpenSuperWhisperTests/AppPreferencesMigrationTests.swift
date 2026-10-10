import KeyboardShortcuts
import XCTest

@testable import OpenSuperWhisper

/// What `AppPreferences` does on first touch to preferences left by older builds.
///
/// These migrations run once per launch, before any UI, on the user's real preferences, and
/// they are about to move behind a lazily installed provider. Each test empties the test
/// process's store, seeds the keys an older build would have left, replays `runMigrations()`
/// (the same function `init` runs, in the same order) and pins what comes out. Expected values
/// are literals, never the result of calling the migration helpers again.
final class AppPreferencesMigrationTests: XCTestCase {

    private static let secretAccounts = ["groqAPIKey", "remoteServerAPIKey"]

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared
    private let defaults = DefaultsStore.current

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences(keychainAccounts: Self.secretAccounts)
    }

    override func tearDown() {
        scratch.restore()
        super.tearDown()
    }

    /// The shortcut a fresh install gets. Under tests the migration reads this instead of the
    /// user's real binding (KeyboardShortcuts only reads UserDefaults.standard), see
    /// `migrateRecordingTriggers`.
    private let defaultToggleShortcut = KeyboardShortcuts.Shortcut(.backtick, modifiers: .option)

    private func storedJSON(_ key: String) throws -> NSDictionary {
        let string = try XCTUnwrap(defaults.string(forKey: key), key)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? NSDictionary)
    }

    // MARK: - Order

    /// The list and order `init` runs. Order matters where one step reads what another wrote:
    /// the trigger conflict check must see the triggers the migration just built.
    func testFreshInstallWritesExactlyTheseKeys() {
        prefs.runMigrations()

        XCTAssertEqual(scratch.writtenKeys,
                       ["appContextProfilesData", "didSeedAppContextPresets", "indicatorLayout", "recordingTriggers"])
        XCTAssertEqual(prefs.selectedEngine, "whisper")
        XCTAssertNil(defaults.object(forKey: "aiBackend"))
    }

    /// The store's contents with JSON values parsed, since JSONEncoder does not keep key order
    /// from one encode to the next and a rewrite of the same value is not a change.
    private var domain: NSDictionary {
        let name = DefaultsStore.testSuiteName(for: ProcessInfo.processInfo.processIdentifier)
        let raw = defaults.persistentDomain(forName: name) ?? [:]
        return raw.mapValues { value -> Any in
            let data = (value as? Data) ?? (value as? String).map { Data($0.utf8) }
            return data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? value
        } as NSDictionary
    }

    /// Nearly idempotent: the second launch also sets the onboarding heal flag, because the
    /// trigger list the first launch built is no longer empty and so takes the healing branch
    /// (which also rewrites the list with the same contents). Nothing else changes, and from the
    /// second launch on nothing changes at all.
    func testSecondLaunchOnlyAddsTheHealFlag() {
        defaults.set("groq", forKey: "selectedEngine")
        defaults.set("remote", forKey: "aiProvider")
        defaults.set("/old.bin", forKey: "selectedModelPath")
        defaults.set("rightOption", forKey: "modifierOnlyHotkey")
        prefs.runMigrations()
        let first = domain
        XCTAssertNil(first["onboardingTriggerHealed"])

        prefs.runMigrations()
        let second = domain

        let expected = first.mutableCopy() as! NSMutableDictionary
        expected["onboardingTriggerHealed"] = true
        XCTAssertEqual(second, expected)

        prefs.runMigrations()
        XCTAssertEqual(domain, second)
    }

    // MARK: - selectedModelPath

    func testOldModelPathIsCopiedToTheWhisperPath() {
        defaults.set("/Users/u/models/ggml-base.bin", forKey: "selectedModelPath")

        prefs.runMigrations()

        XCTAssertEqual(prefs.selectedWhisperModelPath, "/Users/u/models/ggml-base.bin")
        XCTAssertEqual(defaults.string(forKey: "selectedModelPath"), "/Users/u/models/ggml-base.bin",
                       "the old key is left in place")
    }

    func testOldModelPathNeverOverwritesTheWhisperPath() {
        defaults.set("/old.bin", forKey: "selectedModelPath")
        prefs.selectedWhisperModelPath = "/new.bin"

        prefs.runMigrations()

        XCTAssertEqual(prefs.selectedWhisperModelPath, "/new.bin")
    }

    // MARK: - Groq

    func testGroqUserMovesToTheRemoteEngine() {
        defaults.set("groq", forKey: "selectedEngine")
        defaults.set("whisper-large-v3", forKey: "groqModel")
        prefs.groqAPIKey = "gsk-legacy"

        prefs.runMigrations()

        XCTAssertEqual(prefs.selectedEngine, "remote")
        XCTAssertEqual(prefs.remoteServerURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(prefs.remoteServerModel, "whisper-large-v3")
        XCTAssertEqual(prefs.remoteServerAPIKey, "gsk-legacy")
        XCTAssertEqual(prefs.groqAPIKey, "gsk-legacy", "the legacy secret is not deleted")
        XCTAssertEqual(defaults.string(forKey: "groqModel"), "whisper-large-v3")
    }

    /// No stored Groq model means the old default, which is what that user was transcribing with.
    func testGroqUserWithoutAStoredModelGetsTheOldDefault() {
        defaults.set("groq", forKey: "selectedEngine")

        prefs.runMigrations()

        XCTAssertEqual(prefs.remoteServerModel, "whisper-large-v3-turbo")
        XCTAssertNil(prefs.remoteServerAPIKey, "no Groq key, no remote key")
    }

    /// Remote settings the user already typed win over the Groq ones.
    func testGroqMigrationKeepsExistingRemoteSettings() {
        defaults.set("groq", forKey: "selectedEngine")
        prefs.groqAPIKey = "gsk-legacy"
        prefs.remoteServerURL = "http://speaches.lan:8000/v1"
        prefs.remoteServerModel = "Systran/faster-whisper-small"
        prefs.remoteServerAPIKey = "own-key"

        prefs.runMigrations()

        XCTAssertEqual(prefs.selectedEngine, "remote")
        XCTAssertEqual(prefs.remoteServerURL, "http://speaches.lan:8000/v1")
        XCTAssertEqual(prefs.remoteServerModel, "Systran/faster-whisper-small")
        XCTAssertEqual(prefs.remoteServerAPIKey, "own-key")
    }

    func testNonGroqEngineIsLeftAlone() {
        prefs.selectedEngine = "fluidaudio"
        prefs.groqAPIKey = "gsk-legacy"

        prefs.runMigrations()

        XCTAssertEqual(prefs.selectedEngine, "fluidaudio")
        XCTAssertEqual(prefs.remoteServerURL, "")
        XCTAssertNil(prefs.remoteServerAPIKey)
    }

    // MARK: - aiProvider

    func testLegacyAIProviderBecomesTheBackend() {
        defaults.set("remote", forKey: "aiProvider")

        prefs.runMigrations()

        XCTAssertEqual(prefs.aiBackend, "remote")
        XCTAssertEqual(defaults.string(forKey: "aiProvider"), "remote", "the old key is left in place")
    }

    func testLegacyAIProviderNeverOverridesAChosenBackend() {
        defaults.set("remote", forKey: "aiProvider")
        prefs.aiBackend = "builtin"

        prefs.runMigrations()

        XCTAssertEqual(prefs.aiBackend, "builtin")
    }

    /// Copied as is, without checking it names a backend that still exists.
    func testLegacyAIProviderIsCopiedVerbatim() {
        defaults.set("lmstudio", forKey: "aiProvider")
        prefs.runMigrations()
        XCTAssertEqual(prefs.aiBackend, "lmstudio")

        scratch.wipe()
        defaults.set("", forKey: "aiProvider")
        prefs.runMigrations()
        XCTAssertNil(defaults.object(forKey: "aiBackend"), "an empty provider writes nothing")
    }

    // MARK: - Indicator layout

    func testIndicatorSwitchesBecomeALayout() {
        let cases: [(String, Bool, Bool, IndicatorLayout)] = [
            ("replacesDot", false, false, IndicatorLayout(
                order: [.waveform, .label, .dot, .stopButton, .cancelButton],
                hidden: [.dot, .stopButton, .cancelButton], waveformHeight: 30)),
            ("off", true, false, IndicatorLayout(
                order: [.dot, .label, .waveform, .stopButton, .cancelButton],
                hidden: [.waveform, .cancelButton], waveformHeight: 30)),
            ("besideLabel", true, true, IndicatorLayout(
                order: [.dot, .label, .waveform, .stopButton, .cancelButton],
                hidden: [], waveformHeight: 30)),
            ("unknown-mode", false, true, IndicatorLayout(
                order: [.waveform, .label, .dot, .stopButton, .cancelButton],
                hidden: [.dot, .stopButton], waveformHeight: 30)),
        ]
        for (mode, stop, cancel, expected) in cases {
            scratch.wipe()
            defaults.set(mode, forKey: "indicatorMeterMode")
            defaults.set(stop, forKey: "showStopButtonOnIndicator")
            defaults.set(cancel, forKey: "showCancelButtonOnIndicator")

            prefs.runMigrations()

            let stored = IndicatorLayout.load(from: prefs.indicatorLayout)
            XCTAssertEqual(stored, expected, mode)
        }
    }

    /// The stored layout's JSON keys, read back by every later launch.
    func testIndicatorLayoutJSONKeys() throws {
        prefs.runMigrations()
        let keys = try XCTUnwrap(storedJSON("indicatorLayout").allKeys as? [String])
        XCTAssertEqual(Set(keys), ["order", "hidden", "waveformHeight"])
    }

    func testExistingIndicatorLayoutIsKept() {
        let custom = IndicatorLayout(order: [.label, .dot, .waveform, .stopButton, .cancelButton],
                                     hidden: [], waveformHeight: 22)
        prefs.indicatorLayout = custom.json
        defaults.set("off", forKey: "indicatorMeterMode")

        prefs.runMigrations()

        XCTAssertEqual(IndicatorLayout.load(from: prefs.indicatorLayout), custom)
    }

    // MARK: - Recording triggers

    /// The three single-slot preferences all carry over, shortcut first, and the stored JSON keeps
    /// the shape older builds can read (Swift's synthesized enum coding, KeyboardShortcuts'
    /// carbon fields).
    func testSingleSlotTriggersBecomeTheList() throws {
        defaults.set("rightOption", forKey: "modifierOnlyHotkey")
        defaults.set("button4", forKey: "mouseButtonHotkey")

        prefs.runMigrations()

        XCTAssertEqual(RecordingTriggerSet.load(from: prefs.recordingTriggers).triggers,
                       [.keyCombo(defaultToggleShortcut), .modifier(.rightOption), .mouse(.button4)])
        XCTAssertEqual(try storedJSON("recordingTriggers"), [
            "triggers": [
                ["keyCombo": ["_0": ["carbonKeyCode": 50, "carbonModifiers": 2048]]],
                ["modifier": ["_0": "rightOption"]],
                ["mouse": ["_0": "button4"]],
            ],
        ] as NSDictionary)
        XCTAssertEqual(prefs.holdRecordingTriggers, "", "the hold-only list is never seeded")
    }

    func testFreshInstallGetsOnlyTheDefaultShortcut() {
        prefs.runMigrations()
        XCTAssertEqual(RecordingTriggerSet.load(from: prefs.recordingTriggers).triggers,
                       [.keyCombo(defaultToggleShortcut)])
    }

    /// Installs onboarded with the old bug: the list exists without Right Option while the old
    /// key says Right Option. Healed once; removing it afterwards sticks.
    func testOnboardingRightOptionIsHealedOnce() {
        prefs.recordingTriggers = RecordingTriggerSet(triggers: [.mouse(.middle)]).json
        defaults.set("rightOption", forKey: "modifierOnlyHotkey")

        prefs.runMigrations()

        XCTAssertEqual(RecordingTriggerSet.load(from: prefs.recordingTriggers).triggers,
                       [.mouse(.middle), .modifier(.rightOption)])
        XCTAssertTrue(defaults.bool(forKey: "onboardingTriggerHealed"))

        prefs.setRightOptionTrigger(false)
        prefs.runMigrations()

        XCTAssertEqual(RecordingTriggerSet.load(from: prefs.recordingTriggers).triggers, [.mouse(.middle)])
    }

    func testHealingSkipsRightOptionAlreadyHeldOnly() {
        prefs.recordingTriggers = RecordingTriggerSet(triggers: [.mouse(.middle)]).json
        prefs.holdRecordingTriggers = RecordingTriggerSet(triggers: [.modifier(.rightOption)]).json
        defaults.set("rightOption", forKey: "modifierOnlyHotkey")

        prefs.runMigrations()

        XCTAssertEqual(RecordingTriggerSet.load(from: prefs.recordingTriggers).triggers, [.mouse(.middle)])
        XCTAssertTrue(defaults.bool(forKey: "onboardingTriggerHealed"), "the flag is set either way")
    }

    // MARK: - Trigger conflicts

    /// A key bound both as a trigger and as stop-and-submit loses its submit binding. It runs
    /// after the trigger migration, so a legacy single slot that clashes is caught too.
    func testSubmitBindingThatClashesWithATriggerIsCleared() {
        defaults.set("rightOption", forKey: "modifierOnlyHotkey")
        prefs.submitModifierOnlyHotkey = "rightOption"
        prefs.holdRecordingTriggers = RecordingTriggerSet(triggers: [.mouse(.button5)]).json
        prefs.submitMouseButtonHotkey = "button5"

        prefs.runMigrations()

        XCTAssertEqual(prefs.submitModifierOnlyHotkey, "none")
        XCTAssertEqual(prefs.submitMouseButtonHotkey, "none")
    }

    func testSubmitBindingWithoutAClashIsKept() {
        prefs.submitModifierOnlyHotkey = "rightCommand"
        prefs.submitMouseButtonHotkey = "button6"

        prefs.runMigrations()

        XCTAssertEqual(prefs.submitModifierOnlyHotkey, "rightCommand")
        XCTAssertEqual(prefs.submitMouseButtonHotkey, "button6")
    }

    // MARK: - App-context presets

    func testPresetsAreSeededOnceIntoAnEmptyList() {
        prefs.runMigrations()

        XCTAssertEqual(prefs.appContextProfiles.map(\.bundleIdentifier),
                       ["com.tinyspeck.slackmacgap", "com.apple.Terminal"])
        XCTAssertTrue(prefs.didSeedAppContextPresets)

        prefs.appContextProfiles = []
        prefs.runMigrations()

        XCTAssertEqual(prefs.appContextProfiles, [], "deleted presets stay deleted")
    }

    func testPresetsNeverClobberUserProfiles() {
        let own = AppContextProfile(bundleIdentifier: "com.example.editor", appName: "Editor", instructions: "x")
        prefs.appContextProfiles = [own]

        prefs.runMigrations()

        XCTAssertEqual(prefs.appContextProfiles, [own])
        XCTAssertTrue(prefs.didSeedAppContextPresets)
    }
}
