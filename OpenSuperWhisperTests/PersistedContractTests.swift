import FluidAudio
import KeyboardShortcuts
import Security
import XCTest

@testable import OpenSuperWhisper

/// Strings that leave the process: stored in the user's preferences, Keychain, database or log,
/// or read by another process. The compiler cannot see any of them, so moving the code that owns
/// them into a package could change a spelling with every test still green. Each one is copied
/// here as a literal on purpose: comparing a constant with itself would pin nothing.
final class PersistedContractTests: XCTestCase {

    // MARK: - No-speech marker

    /// Compared by value downstream (never pasted, shown as feedback, stored in history rows), so
    /// existing recordings carry this exact text.
    func testNoSpeechMarker() {
        XCTAssertEqual(TranscriptionResult.noSpeech, "No speech detected in the audio")
    }

    // MARK: - Notification names

    /// Observers match on the raw name. The agent request is a distributed notification, posted
    /// by the hook process and heard by the app, so the two sides can be different builds.
    func testNotificationRawNames() {
        let names: [(Notification.Name, String)] = [
            (AgentBridge.requestNotification, "fr.my-monkey.opensuperwhisper.agent.request"),
            (RecordingStore.recordingsDidUpdateNotification, "RecordingStore.recordingsDidUpdate"),
            (RecordingStore.recordingProgressDidUpdateNotification, "RecordingStore.recordingProgressDidUpdate"),
            (RemoteUserPresets.didChangeNotification, "RemoteUserPresetsDidChange"),
            (AppContextModelRules.didChangeNotification, "AppContextModelRulesDidChange"),
            (.microphoneDidChange, "microphoneDidChange"),
            (.appPreferencesLanguageChanged, "AppPreferencesLanguageChanged"),
            (.hotkeySettingsChanged, "HotkeySettingsChanged"),
            (.focusTranscriptionSearch, "FocusTranscriptionSearch"),
            (.showSettingsPane, "ShowSettingsPane"),
            (.showTranscriptions, "ShowTranscriptions"),
            (.indicatorWindowDidHide, "IndicatorWindowDidHide"),
            (.modelSelectionDidChange, "ModelSelectionDidChange"),
            (.translateSettingDidChange, "TranslateSettingDidChange"),
        ]
        for (name, raw) in names {
            XCTAssertEqual(name.rawValue, raw)
        }
    }

    // MARK: - Diagnostics log

    /// The documented retrieval command filters on this subsystem
    /// (`log show --predicate 'subsystem == "fr.my-monkey.opensuperwhisper"'`), and so does
    /// anyone with a saved Console filter. `Diag.log` is built from these two constants.
    func testDiagLogSubsystemAndCategory() {
        XCTAssertEqual(Diag.subsystem, "fr.my-monkey.opensuperwhisper")
        XCTAssertEqual(Diag.category, "hotpath")
    }

    // MARK: - Keychain

    /// Every shipped build keeps the user's API keys under this service. The test host uses
    /// another one (see `TestIsolationTests`), so the production constant is pinned directly.
    func testKeychainProductionService() {
        XCTAssertEqual(Keychain.productionService, "fr.my-monkey.opensuperwhisper")
    }

    /// The account each secret is stored under, observed through the real accessors: written
    /// with the property, read back with the raw account name.
    ///
    /// Read back with a query written out here rather than through `Keychain.read`, which shares
    /// its class and attributes with `Keychain.set`: a move that changed both the same way (another
    /// item class, an access group, the data-protection keychain) would agree with itself and
    /// still lose every key 0.13.3 saved. This is the lookup 0.13.3 does.
    func testKeychainAccountNames() throws {
        let presetID = UUID(uuidString: "6F1C2B3A-0000-4000-8000-000000000001")!
        let presetAccount = "remotePreset.6F1C2B3A-0000-4000-8000-000000000001"
        let accounts = ["groqAPIKey", "remoteServerAPIKey", "aiRemoteAPIKey", presetAccount]
        let scratch = ScratchPreferences(keychainAccounts: accounts)
        defer { scratch.restore() }
        let prefs = AppPreferences.shared

        prefs.groqAPIKey = "groq-secret"
        prefs.remoteServerAPIKey = "remote-secret"
        prefs.aiRemoteAPIKey = "cleanup-secret"
        RemoteUserPresets.setAPIKey("preset-secret", for: presetID)

        let expected = [("groqAPIKey", "groq-secret"), ("remoteServerAPIKey", "remote-secret"),
                        ("aiRemoteAPIKey", "cleanup-secret"), (presetAccount, "preset-secret")]
        for (account, value) in expected {
            let item = try XCTUnwrap(Self.keychainItem(account: account), account)
            XCTAssertEqual((item[kSecValueData as String] as? Data).flatMap { String(data: $0, encoding: .utf8) },
                           value, account)
            // 0.13.3 sets no access group; `testKeychainAddAttributes` pins the write side.
            XCTAssertNil(item[kSecAttrAccessGroup as String], account)
        }
    }

    /// What every write adds, beyond the lookup attributes: the data and its accessibility.
    /// Checked on the query because the legacy file keychain leaves `kSecAttrAccessible` out of
    /// what a read returns (observed on macOS 27), so the item itself cannot show it.
    func testKeychainAddAttributes() {
        let data = Data("secret".utf8)
        let add = Keychain.addQuery(for: "groqAPIKey", data: data)

        XCTAssertEqual(Set(add.keys), [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String,
                                       kSecValueData as String, kSecAttrAccessible as String])
        XCTAssertEqual(add[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(add[kSecAttrService as String] as? String, Keychain.service)
        XCTAssertEqual(add[kSecAttrAccount as String] as? String, "groqAPIKey")
        XCTAssertEqual(add[kSecValueData as String] as? Data, data)
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(Set(Keychain.itemQuery(for: "groqAPIKey").keys),
                       [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String])
    }

    /// The generic-password lookup 0.13.3 does, with nothing added: no access group, no
    /// data-protection keychain. Returns the item's attributes and its data.
    private static func keychainItem(account: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keychain.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? [String: Any]
    }

    /// An empty string deletes the item rather than storing an empty secret, for both kinds of
    /// accessor. Callers treat nil and "" alike, so this is what keeps no-auth servers headerless.
    func testEmptySecretDeletesTheItem() {
        let scratch = ScratchPreferences(keychainAccounts: ["aiRemoteAPIKey"])
        defer { scratch.restore() }

        AppPreferences.shared.aiRemoteAPIKey = "x"
        AppPreferences.shared.aiRemoteAPIKey = ""
        XCTAssertNil(Keychain.read("aiRemoteAPIKey"))
    }

    // MARK: - Engine identifiers

    /// `selectedEngine` values as stored by every build, and the model option each maps to.
    /// "groq" is the legacy value the migration rewrites; on its own it maps to no option.
    func testEngineIdentifiers() {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.selectedWhisperModelPath = "/models/ggml-base.bin"
        prefs.fluidAudioModelVersion = "ultra"
        prefs.remoteServerModel = " whisper-1 "

        let expected: [(String, DictationModelOption?)] = [
            ("whisper", DictationModelOption(engine: "whisper", identifier: "/models/ggml-base.bin",
                                             displayName: "ggml-base")),
            ("fluidaudio", DictationModelOption(engine: "fluidaudio", identifier: "ultra", displayName: "ultra")),
            ("sensevoice", DictationModelOption(engine: "sensevoice", identifier: "default",
                                                displayName: "SenseVoice")),
            ("apple", DictationModelOption(engine: "apple", identifier: "default", displayName: "Apple Speech")),
            ("remote", DictationModelOption(engine: "remote", identifier: "whisper-1", displayName: "whisper-1")),
            ("groq", nil),
        ]
        for (engine, option) in expected {
            prefs.selectedEngine = engine
            XCTAssertEqual(ModelCatalog.activeOption(), option, engine)
        }
        XCTAssertEqual(AppPreferences.shared.selectedEngine, "groq")
    }

    // MARK: - Parakeet versions

    /// `fluidAudioModelVersion` values and the model each loads. Anything unknown, including the
    /// empty string, loads v3, which is also the shipped default.
    func testParakeetVersionValues() {
        XCTAssertEqual(AsrModelVersion(preference: "v2"), .v2)
        XCTAssertEqual(AsrModelVersion(preference: "v3"), .v3)
        XCTAssertEqual(AsrModelVersion(preference: "ultra"), .ultra)
        XCTAssertEqual(AsrModelVersion(preference: ""), .v3)
        XCTAssertEqual(AsrModelVersion(preference: "V2"), .v3, "matching is case-sensitive")
        XCTAssertEqual(AsrModelVersion(preference: "redux"), .v3)

        XCTAssertEqual(SettingsFluidAudioModels.availableModels.map(\.version), ["v3", "ultra", "v2"])
    }

    func testParakeetDefaultVersion() {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        XCTAssertEqual(AppPreferences.shared.fluidAudioModelVersion, "v3")
    }

    // MARK: - Shortcut names

    /// KeyboardShortcuts stores each binding in UserDefaults.standard under "KeyboardShortcuts_"
    /// plus this name, so renaming one unbinds the user's shortcut.
    func testKeyboardShortcutNames() {
        XCTAssertEqual(KeyboardShortcuts.Name.toggleRecord.rawValue, "toggleRecord")
        XCTAssertEqual(KeyboardShortcuts.Name.escape.rawValue, "escape")
        XCTAssertEqual(KeyboardShortcuts.Name.pasteLastTranscription.rawValue, "pasteLastTranscription")
        XCTAssertEqual(KeyboardShortcuts.Name.toggleRecordAndSubmit.rawValue, "toggleRecordAndSubmit")
        XCTAssertEqual(KeyboardShortcuts.Name.recordTriggerSlot(3).rawValue, "recordTriggerSlot3")
        XCTAssertEqual(KeyboardShortcuts.Name.holdTriggerSlot(0).rawValue, "holdTriggerSlot0")
    }

    // MARK: - Codable payloads stored as JSON in preferences

    private func jsonKeys<T: Encodable>(_ value: T) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return Set(try XCTUnwrap(object as? [String: Any]).keys)
    }

    /// Stored in `appModelRules` (a map of these) and `remoteFallbackModelData`.
    func testDictationModelOptionKeys() throws {
        let option = DictationModelOption(engine: "fluidaudio", identifier: "v3", displayName: "Parakeet v3")
        XCTAssertEqual(try jsonKeys(option), ["engine", "identifier", "displayName"])
    }

    /// A rule map exactly as 0.13.3 writes it still decodes, keyed by "bundleID" or
    /// "bundleID|host".
    func testStoredModelRulesDecode() {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        AppPreferences.shared.appModelRulesData = Data("""
            {"com.tinyspeck.slackmacgap":{"engine":"fluidaudio","identifier":"v2","displayName":"Parakeet v2"},\
            "com.google.Chrome|github.com":{"engine":"remote","identifier":"whisper-1","displayName":"whisper-1"}}
            """.utf8)

        XCTAssertEqual(AppContextModelRules.rule(for: "com.tinyspeck.slackmacgap"),
                       DictationModelOption(engine: "fluidaudio", identifier: "v2", displayName: "Parakeet v2"))
        XCTAssertEqual(AppContextModelRules.rule(for: "com.google.Chrome", host: "github.com"),
                       DictationModelOption(engine: "remote", identifier: "whisper-1", displayName: "whisper-1"))
    }

    /// Stored in `remoteUserPresets`; the API key is deliberately not one of the keys.
    func testRemoteUserPresetKeys() throws {
        let preset = RemoteUserPreset(id: UUID(), name: "n", serverURL: "u", model: "m",
                                      timeoutEnabled: true, timeoutSeconds: 30)
        XCTAssertEqual(try jsonKeys(preset),
                       ["id", "name", "serverURL", "model", "timeoutEnabled", "timeoutSeconds"])
    }

    /// Stored in `customDictionaryData`. The decoder also accepts entries saved before
    /// `alternates`, `spacing` and `isRegex` existed.
    func testCustomDictionaryEntryKeys() throws {
        XCTAssertEqual(try jsonKeys(CustomDictionaryEntry(original: "a", replacement: "b")),
                       ["id", "original", "replacement", "alternates", "spacing", "isRegex"])

        let legacy = Data(#"[{"id":"6F1C2B3A-0000-4000-8000-000000000002","original":"osw","replacement":"OSW"}]"#.utf8)
        let entries = try JSONDecoder().decode([CustomDictionaryEntry].self, from: legacy)
        XCTAssertEqual(entries.first?.replacement, "OSW")
        XCTAssertEqual(entries.first?.alternates, [])
        XCTAssertEqual(entries.first?.spacing, .standalone)
        XCTAssertEqual(entries.first?.isRegex, false)
    }

    /// Stored in the `status` column of every recording row.
    func testRecordingStatusRawValues() {
        XCTAssertEqual(RecordingStatus.pending.rawValue, "pending")
        XCTAssertEqual(RecordingStatus.converting.rawValue, "converting")
        XCTAssertEqual(RecordingStatus.transcribing.rawValue, "transcribing")
        XCTAssertEqual(RecordingStatus.completed.rawValue, "completed")
        XCTAssertEqual(RecordingStatus.failed.rawValue, "failed")
    }
}
