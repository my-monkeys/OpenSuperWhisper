//
//  TriggerPermissionTests.swift
//  OpenSuperWhisperTests
//
//  Granting Accessibility or Input Monitoring must re-arm the recording triggers, which used to
//  stay dead until the app was relaunched.
//

import Combine
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class TriggerPermissionTests: XCTestCase {

    private typealias Permissions = ShortcutManager.TriggerPermissions

    private func rearmCount(for changes: [Permissions]) -> Int {
        let subject = PassthroughSubject<Permissions, Never>()
        let manager = ShortcutManager()
        var count = 0
        manager.rearmTriggers(onChangeOf: subject.eraseToAnyPublisher()) { count += 1 }
        changes.forEach(subject.send)
        return count
    }

    func testTheStateAtLaunchDoesNotRearm() {
        XCTAssertEqual(rearmCount(for: [Permissions(accessibility: false, inputMonitoring: false)]), 0)
    }

    func testGrantingAccessibilityRearms() {
        XCTAssertEqual(rearmCount(for: [Permissions(accessibility: false, inputMonitoring: false),
                                        Permissions(accessibility: true, inputMonitoring: false)]), 1)
    }

    func testGrantingInputMonitoringRearms() {
        XCTAssertEqual(rearmCount(for: [Permissions(accessibility: true, inputMonitoring: false),
                                        Permissions(accessibility: true, inputMonitoring: true)]), 1)
    }

    func testAnUnchangedPollDoesNotRearm() {
        let state = Permissions(accessibility: true, inputMonitoring: true)
        XCTAssertEqual(rearmCount(for: [state, state, state]), 0)
    }
}
