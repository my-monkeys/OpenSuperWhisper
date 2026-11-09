//
//  ModifierSideTests.swift
//  OpenSuperWhisperTests
//
//  Which physical modifier is down. The generic mask is shared by both sides, so a trigger bound
//  to the right Option never saw its release while the left Option was held.
//

import CoreGraphics
import XCTest
@testable import OpenSuperWhisper

final class ModifierSideTests: XCTestCase {

    private let sides: [(left: ModifierKey, right: ModifierKey)] = [
        (.leftCommand, .rightCommand), (.leftOption, .rightOption),
        (.leftShift, .rightShift), (.leftControl, .rightControl),
    ]

    /// The flags macOS reports: the generic mask plus the bit of each side that is down.
    private func flags(_ down: ModifierKey...) -> CGEventFlags {
        var raw: UInt64 = 0
        for key in down {
            raw |= key.cgEventFlag.rawValue
            raw |= deviceBit(key)
        }
        return CGEventFlags(rawValue: raw)
    }

    private func deviceBit(_ key: ModifierKey) -> UInt64 {
        switch key {
        case .leftCommand: return UInt64(NX_DEVICELCMDKEYMASK)
        case .rightCommand: return UInt64(NX_DEVICERCMDKEYMASK)
        case .leftOption: return UInt64(NX_DEVICELALTKEYMASK)
        case .rightOption: return UInt64(NX_DEVICERALTKEYMASK)
        case .leftShift: return UInt64(NX_DEVICELSHIFTKEYMASK)
        case .rightShift: return UInt64(NX_DEVICERSHIFTKEYMASK)
        case .leftControl: return UInt64(NX_DEVICELCTLKEYMASK)
        case .rightControl: return UInt64(NX_DEVICERCTLKEYMASK)
        default: return 0
        }
    }

    func testAKeyIsDownWhenItsOwnSideIsHeld() {
        for (left, right) in sides {
            XCTAssertTrue(left.isDown(in: flags(left)))
            XCTAssertTrue(right.isDown(in: flags(right)))
        }
    }

    func testReleasingOneSideWhileTheOtherIsHeldReadsAsReleased() {
        for (left, right) in sides {
            XCTAssertFalse(right.isDown(in: flags(left)), "\(right) released, \(left) still down")
            XCTAssertFalse(left.isDown(in: flags(right)), "\(left) released, \(right) still down")
        }
    }

    func testBothSidesHeldReadsAsBothDown() {
        for (left, right) in sides {
            XCTAssertTrue(left.isDown(in: flags(left, right)))
            XCTAssertTrue(right.isDown(in: flags(left, right)))
        }
    }

    func testFnHasNoSide() {
        XCTAssertTrue(ModifierKey.fn.isDown(in: .maskSecondaryFn))
        XCTAssertFalse(ModifierKey.fn.isDown(in: []))
    }

    func testNothingIsDownWithNoFlags() {
        for key in ModifierKey.allCases {
            XCTAssertFalse(key.isDown(in: []))
        }
    }
}
