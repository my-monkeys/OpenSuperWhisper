import Foundation

/// A crash or hang MetricKit handed back, reduced to the lines that say where the app stopped.
///
/// Built from plain fields, not an `MXCrashDiagnostic`, which has no public initializer: this is
/// the part that decides what a report says and how long it may be, and it has to be testable on
/// its own. The MetricKit subscriber fills it in; nothing here reaches for a live payload.
struct CrashReportDraft: Equatable {
    enum Kind: String {
        case crash
        case hang
    }

    var kind: Kind
    /// The Mach exception, the BSD signal, or the OS's termination reason, whichever the payload
    /// carried. One short line, never the audio or the dictation, which a crash payload never holds.
    var cause: String
    /// The crashing (or stuck) thread's frames, in the tree's order, each a binary, an address and
    /// an offset into the binary. MetricKit gives no source paths, and a report would not send one
    /// if it did.
    var frames: [String]
    /// One `image <binary> <UUID>` line per binary the frames come from: what the offsets need to
    /// be symbolicated against the right build.
    var images: [String] = []
    /// The build that crashed, which can be older than the one now reading the report.
    var appVersion: String
    var osVersion: String
}

/// Turns a `CrashReportDraft` into a message and a submission the feedback endpoint accepts.
enum CrashReport {

    /// A cause above zero or more positioned frames can keep the report under the endpoint's limit.
    private static let maxCauseLength = 200

    /// The report's text: the cause, then as many frames as fit, numbered from the top, then every
    /// image line. The deepest frames are the first to go, because the fault sits at the top of the
    /// stack; the image lines never go, since no frame can be symbolicated without them.
    static func message(for draft: CrashReportDraft, frameLimit: Int) -> String {
        let cause = String(draft.cause.prefix(maxCauseLength))
        let header = "\(draft.kind.rawValue): \(cause)"
        let frames = draft.frames.prefix(max(0, frameLimit)).enumerated().map { "#\($0.offset) \($0.element)" }
        return ([header] + frames + draft.images).joined(separator: "\n")
    }

    /// An anonymous submission (no email) whose context names the build that crashed. The message
    /// is trimmed one frame at a time, the image lines counting toward the limit but never trimmed, until the endpoint would take it, so even a very deep stack
    /// sends its top rather than nothing.
    static func submission(for draft: CrashReportDraft) -> FeedbackSubmission {
        let details = "OpenSuperWhisper \(draft.appVersion) · macOS \(draft.osVersion)"
        var frameLimit = draft.frames.count
        while true {
            let submission = FeedbackSubmission(kind: .crash,
                                                message: message(for: draft, frameLimit: frameLimit),
                                                email: "",
                                                details: details)
            if frameLimit == 0 || FeedbackSender.fitsLimits(submission) {
                return submission
            }
            frameLimit -= 1
        }
    }
}
