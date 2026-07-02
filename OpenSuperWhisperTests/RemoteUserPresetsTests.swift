import XCTest
@testable import OpenSuperWhisper

/// CRUD + persistence round-trip for user-defined Remote presets. The API key is
/// stored per preset in the Keychain (never in the JSON payload) and must be
/// removed with its preset so no orphaned secret survives.
final class RemoteUserPresetsTests: XCTestCase {

    private var savedData = Data()

    override func setUp() {
        super.setUp()
        savedData = AppPreferences.shared.remoteUserPresetsData
        AppPreferences.shared.remoteUserPresetsData = Data()
    }

    override func tearDown() {
        AppPreferences.shared.remoteUserPresetsData = savedData
        super.tearDown()
    }

    private func makePreset(name: String = "Test Server") -> RemoteUserPreset {
        RemoteUserPreset(
            id: UUID(), name: name, serverURL: "http://litellm.lan:4000/v1",
            model: "whisper-large-v3", timeoutEnabled: true, timeoutSeconds: 30)
    }

    func testAddPersistsAndRoundTrips() {
        let preset = makePreset()
        RemoteUserPresets.add(preset, apiKey: nil)
        XCTAssertEqual(RemoteUserPresets.all(), [preset])
    }

    func testRemoveDeletesPresetAndItsKey() {
        let preset = makePreset()
        RemoteUserPresets.add(preset, apiKey: "sk-secret")
        XCTAssertEqual(RemoteUserPresets.apiKey(for: preset.id), "sk-secret")

        RemoteUserPresets.remove(preset.id)
        XCTAssertTrue(RemoteUserPresets.all().isEmpty)
        XCTAssertNil(RemoteUserPresets.apiKey(for: preset.id), "orphaned secret left in Keychain")
    }

    func testReAddingSameIDReplacesInsteadOfDuplicating() {
        var preset = makePreset()
        RemoteUserPresets.add(preset, apiKey: nil)
        preset.name = "Renamed"
        RemoteUserPresets.add(preset, apiKey: nil)
        XCTAssertEqual(RemoteUserPresets.all().map(\.name), ["Renamed"])
    }

    func testMatchingFindsPresetByURLAndModel() {
        let preset = makePreset()
        RemoteUserPresets.add(preset, apiKey: nil)
        XCTAssertEqual(RemoteUserPresets.matching(url: preset.serverURL, model: preset.model), preset)
        XCTAssertNil(RemoteUserPresets.matching(url: preset.serverURL, model: "other-model"))
        RemoteUserPresets.remove(preset.id)
    }
}
