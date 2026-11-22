import XCTest
@testable import OpenSuperWhisper

final class CodexPluginTests: XCTestCase {
    func testInstallAddsTheMarketplaceThenThePlugin() {
        XCTAssertEqual(CodexPlugin.marketplaceCommand, ["plugin", "marketplace", "add", "my-monkeys/OpenSuperWhisper"])
        XCTAssertEqual(CodexPlugin.installCommand, ["plugin", "add", "opensuperwhisper@opensuperwhisper"])
    }

    func testRemovalNamesThePluginWithItsMarketplace() {
        XCTAssertEqual(CodexPlugin.uninstallCommand, ["plugin", "remove", "opensuperwhisper@opensuperwhisper"])
    }

    func testCodexStateLivesInCodexHomeWhenSetAndInTheDotFolderOtherwise() {
        XCTAssertEqual(CodexPlugin.configURL(environment: ["CODEX_HOME": "/tmp/codex-home"]).path,
                       "/tmp/codex-home/config.toml")
        XCTAssertEqual(CodexPlugin.configURL(environment: [:]).path,
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml").path)
    }

    func testNvmLookupTakesTheNewestNodeThatHasTheCommand() throws {
        let nvm = FileManager.default.temporaryDirectory.appendingPathComponent("nvm-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: nvm) }
        try install("codex", under: "v9.4.0", in: nvm)
        try install("codex", under: "v22.16.0", in: nvm)
        try install("node", under: "v24.0.0", in: nvm)

        XCTAssertEqual(AgentCLI.nvmExecutable(named: "codex", nvmDirectory: nvm),
                       nvm.appendingPathComponent("versions/node/v22.16.0/bin/codex").path,
                       "numeric order, so v22 beats v9, and a version without codex is skipped")
        XCTAssertNil(AgentCLI.nvmExecutable(named: "claude", nvmDirectory: nvm))
    }

    func testNvmLookupFindsNothingWithoutNvm() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-nvm-\(UUID().uuidString)")
        XCTAssertNil(AgentCLI.nvmExecutable(named: "codex", nvmDirectory: missing))
    }

    @MainActor
    func testCodexAloneDoesNotAnswerAnAgentWithoutItsPlugin() {
        let prefs = AppPreferences.shared
        let before = prefs.agentEnabledKinds
        addTeardownBlock { prefs.agentEnabledKinds = before }
        prefs.agentEnabledKinds = []
        let model = AssistantsSettingsModel()
        XCTAssertFalse(model.enabled, "no agent answered: the dependent settings are hidden")
        model.codexOn = true
        XCTAssertFalse(model.enabled, "Codex counts only once its plugin is found")
        model.piOn = true
        XCTAssertTrue(model.enabled)
    }

    private func install(_ name: String, under version: String, in nvm: URL) throws {
        let bin = nvm.appendingPathComponent("versions/node/\(version)/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let file = bin.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
}
