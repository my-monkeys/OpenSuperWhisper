import XCTest
@testable import OpenSuperWhisper

/// Commit 0, scenario 7: pin AppPreferences' once-per-process init migrations by
/// re-running them through the `AppPreferences(forTesting: true)` seam against seeded
/// UserDefaults/Keychain state. Every touched key (defaults AND keychain) is snapshotted
/// in setUp and restored in tearDown — hosted tests share the app's real stores.
final class AppPreferencesMigrationTests: XCTestCase {

    private enum Keys {
        static let selectedModelPath = "selectedModelPath"
        static let selectedWhisperModelPath = "selectedWhisperModelPath"
        static let selectedEngine = "selectedEngine"
        static let groqModel = "groqModel"
        static let remoteServerURL = "remoteServerURL"
        static let remoteServerModel = "remoteServerModel"
    }

    private var savedDefaults: [(key: String, value: String?)] = []
    private var savedGroqKey: String??
    private var savedRemoteKey: String??

    override func setUp() {
        super.setUp()
        let defaults = [Keys.selectedModelPath, Keys.selectedWhisperModelPath, Keys.selectedEngine,
                        Keys.groqModel, Keys.remoteServerURL, Keys.remoteServerModel]
        // Array-of-tuples, NOT a dictionary: dict[key] = nil deletes the entry, which
        // would lose the "originally absent → must be removed in tearDown" state.
        for key in defaults {
            savedDefaults.append((key, UserDefaults.standard.string(forKey: key)))
        }
        savedGroqKey = .some(Keychain.read("groqAPIKey"))
        savedRemoteKey = .some(Keychain.read("remoteServerAPIKey"))
    }

    override func tearDown() {
        for (key, value) in savedDefaults {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        Keychain.set(savedGroqKey ?? nil, for: "groqAPIKey")
        Keychain.set(savedRemoteKey ?? nil, for: "remoteServerAPIKey")
        super.tearDown()
    }

    private func seed(_ key: String, _ value: Any?) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - migrateOldPreferences (selectedModelPath → selectedWhisperModelPath)

    func testLegacyModelPathMigratesWhenNewKeyAbsent() {
        seed(Keys.selectedModelPath, "/old/models/ggml-base.bin")
        seed(Keys.selectedWhisperModelPath, nil)

        _ = AppPreferences(forTesting: true)

        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.selectedWhisperModelPath),
                       "/old/models/ggml-base.bin", "legacy path must be copied to the new key")
    }

    func testLegacyModelPathDoesNotOverwriteExistingNewKey() {
        seed(Keys.selectedModelPath, "/old/models/ggml-base.bin")
        seed(Keys.selectedWhisperModelPath, "/new/models/ggml-tiny.bin")

        _ = AppPreferences(forTesting: true)

        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.selectedWhisperModelPath),
                       "/new/models/ggml-tiny.bin", "an existing new-key value must win")
    }

    // MARK: - migrateGroqToRemote

    private func seedGroqUser(engine: String = "groq") {
        seed(Keys.selectedEngine, engine)
        seed(Keys.groqModel, "whisper-large-v3-turbo")
        seed(Keys.remoteServerURL, "")
        seed(Keys.remoteServerModel, "")
        Keychain.set(nil, for: "remoteServerAPIKey")
    }

    func testGroqMigrationSeedsRemoteConfigAndFlipsEngine() {
        seedGroqUser()
        Keychain.set("test-groq-key", for: "groqAPIKey")

        _ = AppPreferences(forTesting: true)

        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.selectedEngine), "remote",
                       "groq users are folded into the remote engine")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.remoteServerURL),
                       "https://api.groq.com/openai/v1")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.remoteServerModel),
                       "whisper-large-v3-turbo", "remote model seeded from the legacy groqModel")
        XCTAssertEqual(Keychain.read("remoteServerAPIKey"), "test-groq-key",
                       "remote API key seeded from the legacy groqAPIKey keychain item")
    }

    func testGroqMigrationPreservesExistingRemoteConfig() {
        seedGroqUser()
        seed(Keys.remoteServerURL, "https://my-server.example/v1")
        seed(Keys.remoteServerModel, "my-model")
        Keychain.set("my-existing-key", for: "remoteServerAPIKey")
        Keychain.set("test-groq-key", for: "groqAPIKey")

        _ = AppPreferences(forTesting: true)

        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.remoteServerURL),
                       "https://my-server.example/v1", "existing remote URL must not be clobbered")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.remoteServerModel), "my-model")
        XCTAssertEqual(Keychain.read("remoteServerAPIKey"), "my-existing-key")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.selectedEngine), "remote",
                       "the engine flip still happens for a groq user with remote config present")
    }

    func testGroqMigrationIsIdempotentAcrossConstructions() {
        seedGroqUser()
        Keychain.set("test-groq-key", for: "groqAPIKey")

        _ = AppPreferences(forTesting: true)
        let urlAfterFirst = UserDefaults.standard.string(forKey: Keys.remoteServerURL)
        let engineAfterFirst = UserDefaults.standard.string(forKey: Keys.selectedEngine)

        // Second construction: the migration's own guard (selectedEngine == "groq") is
        // now false, so nothing may change.
        seed(Keys.remoteServerURL, "https://touched-by-user.example/v1")
        _ = AppPreferences(forTesting: true)

        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.remoteServerURL),
                       "https://touched-by-user.example/v1", "second run must be a no-op")
        XCTAssertEqual(urlAfterFirst, "https://api.groq.com/openai/v1")
        XCTAssertEqual(engineAfterFirst, "remote")
    }

    func testNonGroqEngineIsLeftUntouched() {
        seed(Keys.selectedEngine, "whisper")
        seed(Keys.remoteServerURL, "")
        seed(Keys.remoteServerModel, "")

        _ = AppPreferences(forTesting: true)

        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.selectedEngine), "whisper")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.remoteServerURL), "")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.remoteServerModel), "")
    }
}
