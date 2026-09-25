import Foundation

/// An Objective-C exception turned into a Swift error, so a `do/catch` can handle it.
struct ObjCExceptionError: LocalizedError {
    let name: String
    let reason: String?

    var errorDescription: String? { "\(name): \(reason ?? "no reason given")" }

    /// Runs `body`, throwing instead of letting an `NSException` unwind through Swift.
    /// See `OSWCatchException` for why this matters beyond the exception itself.
    static func catching(_ body: () -> Void) throws {
        if let exception = OSWCatchException(body) {
            throw ObjCExceptionError(name: exception.name.rawValue, reason: exception.reason)
        }
    }
}
