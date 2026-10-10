import XCTest
@testable import OpenSuperWhisper

/// Which turned-off folder keeps a project's agents in the terminal. The hook and the Agents
/// pane both read it, and they disagreed once: a project under a turned-off folder read on in
/// the pane while its agents never opened the panel (#171).
final class AgentProjectSwitchTests: XCTestCase {

    private func turnedOff(_ path: String, _ disabled: [String]) -> String? {
        AppPreferences.agentProjectTurnedOff(path, by: disabled)
    }

    func testAProjectNothingTurnsOffIsOn() {
        XCTAssertNil(turnedOff("/code/site", []))
        XCTAssertNil(turnedOff("/code/site", ["/code/other"]))
    }

    func testATurnedOffProjectIsTurnedOffByItself() {
        XCTAssertEqual(turnedOff("/code/site", ["/code/site"]), "/code/site")
    }

    func testASubfolderIsTurnedOffByItsFolder() {
        XCTAssertEqual(turnedOff("/code/site/docs", ["/code/site"]), "/code/site")
        XCTAssertEqual(turnedOff("/code/site/docs/api", ["/code/site"]), "/code/site")
    }

    func testASiblingThatSharesTheNameIsNotCovered() {
        XCTAssertNil(turnedOff("/a/foobar", ["/a/foo"]))
        XCTAssertNil(turnedOff("/a/foo", ["/a/foobar"]))
        XCTAssertNil(turnedOff("/a/foo-v2/src", ["/a/foo"]))
    }

    func testAParentIsNotTurnedOffByItsSubfolder() {
        XCTAssertNil(turnedOff("/code", ["/code/site"]))
    }

    func testTheNearestTurnedOffFolderWins() {
        let disabled = ["/Users/me", "/Users/me/code/site", "/Users/me/code"]
        XCTAssertEqual(turnedOff("/Users/me/code/site/docs", disabled), "/Users/me/code/site")
        XCTAssertEqual(turnedOff("/Users/me/code/app", disabled), "/Users/me/code")
        XCTAssertEqual(turnedOff("/Users/me/notes", disabled), "/Users/me")
        XCTAssertEqual(turnedOff("/Users/me/code", disabled), "/Users/me/code", "its own switch before its parent's")
    }

    /// Paths are compared as written, the way the hook always has: a trailing slash makes a
    /// different entry, and an entry with one covers nothing below it.
    func testATrailingSlashIsMatchedAsWritten() {
        XCTAssertEqual(turnedOff("/code/site/", ["/code/site/"]), "/code/site/")
        XCTAssertNil(turnedOff("/code/site", ["/code/site/"]))
        XCTAssertNil(turnedOff("/code/site/docs", ["/code/site/"]))
        XCTAssertEqual(turnedOff("/code/site/", ["/code/site"]), "/code/site")
    }

    func testTheHookAgreesWithTheSwitches() {
        let prefs = AppPreferences.shared
        let saved = prefs.agentDisabledProjects
        defer { prefs.agentDisabledProjects = saved }
        let disabled = ["/a/foo", "/Users/me", "/Users/me/code/site", "/code/site/"]
        prefs.agentDisabledProjects = disabled

        let paths = ["/a/foo", "/a/foo/src", "/a/foobar", "/Users/me/code/site/docs", "/Users/me",
                     "/Users/other", "/code/site", "/code/site/", "/code/site/docs", "/"]
        for path in paths {
            XCTAssertEqual(prefs.agentProjectEnabled(path), turnedOff(path, disabled) == nil, path)
        }
    }

    // MARK: The pane's list

    func testATurnedOffFolderOutsideTheRecentListStaysListed() {
        let listed = AgentsSettingsPane.listedProjects(
            recent: ["/Users/me/code/site", "/Users/me/code/app"],
            disabled: ["/Users/me/code/site", "/Users/me/Documents", "/Users/me"])
        XCTAssertEqual(listed, ["/Users/me", "/Users/me/Documents", "/Users/me/code/site", "/Users/me/code/app"])
    }

    func testARowUnderATurnedOffFolderNamesThatFolder() {
        XCTAssertEqual(AgentsSettingsPane.folderTurningOff("/code/site", disabled: ["/code"]), "/code")
        XCTAssertNil(AgentsSettingsPane.folderTurningOff("/code/site", disabled: ["/code/site"]))
        XCTAssertNil(AgentsSettingsPane.folderTurningOff("/code", disabled: ["/code/site"]))
    }

    /// A project turned off on its own, then its folder: the row names the folder (and locks its
    /// switch) rather than offering a switch that would drop the project's own setting.
    func testAProjectOffOnItsOwnAndByItsFolderNamesTheFolder() {
        let disabled = ["/code/site", "/code"]
        XCTAssertEqual(AgentsSettingsPane.folderTurningOff("/code/site", disabled: disabled), "/code")
        XCTAssertEqual(turnedOff("/code/site", disabled.filter { $0 != "/code" }), "/code/site",
                       "the folder back on, the project is still off on its own")
    }

    func testAFolderCountsOnlyTheProjectsItAloneTurnsOff() {
        let projects = ["/a", "/a/b", "/a/b/c", "/a/d", "/a/e", "/x"]
        let disabled = ["/a", "/a/b", "/a/e"]
        func count(_ folder: String) -> Int {
            AgentsSettingsPane.projectsOnlyTurnedOff(by: folder, among: projects, disabled: disabled)
        }
        XCTAssertEqual(count("/a"), 1, "only /a/d comes back with /a on")
        XCTAssertEqual(count("/a/b"), 1)
        XCTAssertEqual(count("/a/e"), 0)
        XCTAssertEqual(count("/x"), 0, "a folder that is on keeps nothing off")
    }
}
