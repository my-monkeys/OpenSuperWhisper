import XCTest
@testable import OpenSuperWhisperCore

/// Base class of every XCTest class in the core target. A SwiftPM test bundle has no principal
/// class, so the environment is installed here, before any instance `setUp` runs.
///
/// Instances are built before the class `setUp`, so a subclass must not read a core singleton
/// from a stored-property initializer.
class CoreTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        CoreTestEnvironment.install()
    }

    override func tearDown() {
        CoreTestEnvironment.preferences.reset()
        super.tearDown()
    }
}
