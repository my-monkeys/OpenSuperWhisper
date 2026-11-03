import Foundation
import OpenSuperWhisperCore

/// The last AI cleanup failure of this launch, for the Settings to show next to the backend
/// status (#264). In memory on purpose: it answers "is it failing right now", and a failure from
/// an earlier launch says nothing about the configuration someone has just fixed.
@MainActor
final class CleanupSessionStatus: ObservableObject {
    static let shared = CleanupSessionStatus()

    struct Failure: Equatable {
        let model: String
        let reason: String
        let date: Date
    }

    @Published private(set) var lastFailure: Failure?

    private init() {}

    /// A failed pass sets it, a pass that worked clears it, and a dictation that ran no pass
    /// leaves it alone: it says nothing about whether the cleanup works.
    func record(_ outcome: CleanupOutcome, at date: Date = Date()) {
        switch outcome.status {
        case .failed(let model, let reason): lastFailure = Failure(model: model, reason: reason, date: date)
        case .cleaned: lastFailure = nil
        case .notRun: break
        }
    }
}
