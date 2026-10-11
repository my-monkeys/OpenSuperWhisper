#if os(macOS)
import Foundation
import Testing
@testable import OpenSuperWhisperCore

/// Reading the core before a configuration is installed, or installing twice, ends the process
/// with a message that says what to do. XCTest cannot observe a trap, so these are exit tests: the
/// body runs in a child process, which starts with nothing installed. The suite never installs the
/// test environment itself. Exit tests do not exist on iOS.
@Suite struct NotInstalledTrapTests {

    @Test func readingBeforeInstallTraps() async throws {
        let result = try #require(await #expect(processExitsWith: .failure,
                                                observing: [\.standardErrorContent]) {
            _ = CoreAccess.storageRoot
        })
        let firstSentence = try #require(CoreConfiguration.notInstalledMessage
            .components(separatedBy: ". ").first)
        #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains(firstSentence))
    }

    @Test func installingTwiceTraps() async throws {
        let result = try #require(await #expect(processExitsWith: .failure,
                                                observing: [\.standardErrorContent]) {
            CoreConfiguration.install(CoreTestEnvironment.configuration)
            CoreConfiguration.install(CoreTestEnvironment.configuration)
        })
        #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("ran twice"))
    }

    @Test func installThenReadSucceeds() async {
        await #expect(processExitsWith: .success) {
            CoreConfiguration.install(CoreTestEnvironment.configuration)
            _ = CoreAccess.storageRoot
        }
    }
}
#endif
