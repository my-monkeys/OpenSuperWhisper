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
    /// The crashing (or stuck) thread's frames, crash site first and thread entry last, each a
    /// binary, an address and an offset into the binary. MetricKit gives no source paths, and a report would not send one
    /// if it did.
    var frames: [String]
    /// One `image <binary> <UUID>` line per binary the frames come from: what the offsets need to
    /// be symbolicated against the right build.
    var images: [String] = []
    /// MetricKit's description of the memory around the faulting address. It says whether that
    /// address was freed heap, which is what proves a use-after-free. Crashes only.
    var memoryRegion: String?
    /// The Objective-C exception's name, class and message, already joined, when the crash was one.
    var exceptionReason: String?
    /// MetricKit's own JSON for the whole diagnostic, every thread and every binary. Raw: it is
    /// stripped of the locale only when the submission is built.
    var diagnosticJSON: Data?
    /// The build that crashed, which can be older than the one now reading the report.
    var appVersion: String
    var appBuild: String
    /// As MetricKit words it, which already starts with "macOS".
    var osVersion: String
}

/// Turns a `CrashReportDraft` into a message and a submission the feedback endpoint accepts.
enum CrashReport {

    /// A cause above zero or more positioned frames can keep the report under the endpoint's limit.
    private static let maxCauseLength = 200
    /// The region and the exception reason are one line each, below the cause, so they do not
    /// share its cap. Both stay far under the 4000-character message limit, and trimming still
    /// takes frames first.
    private static let maxDetailLength = 300

    /// The report's text: the cause, then as many frames as fit, numbered from #0, then every
    /// image line. The outermost frames (the end of the list) are the first to go, because the fault
    /// sits at #0; the image lines never go, since no frame can be symbolicated without them.
    static func message(for draft: CrashReportDraft, frameLimit: Int) -> String {
        let cause = String(draft.cause.prefix(maxCauseLength))
        let header = "\(draft.kind.rawValue): \(cause)"
        let details = [("region", draft.memoryRegion), ("exception", draft.exceptionReason)]
            .compactMap { label, text in text.map { "\(label): \(compacted($0, limit: maxDetailLength))" } }
        let frames = draft.frames.prefix(max(0, frameLimit)).enumerated().map { "#\($0.offset) \($0.element)" }
        return ([header] + details + frames + draft.images).joined(separator: "\n")
    }

    /// "NSInvalidArgumentException (NSArray): the message", from what MetricKit's exception reason holds.
    static func exceptionReason(name: String, className: String, message: String) -> String {
        "\(name) (\(className)): \(message)"
    }

    /// The context line: the build that crashed and its OS. MetricKit's OS string already starts
    /// with "macOS"; anything else gets the prefix.
    static func details(for draft: CrashReportDraft) -> String {
        let os = draft.osVersion.hasPrefix("macOS") ? draft.osVersion : "macOS \(draft.osVersion)"
        return "OpenSuperWhisper \(draft.appVersion) (\(draft.appBuild)) · \(os)"
    }

    /// The diagnostic as `crash-0.15.2-73.json`, or nil when it is absent or cannot be read well
    /// enough to be stripped of the locale.
    static func attachment(for draft: CrashReportDraft) -> FeedbackAttachment? {
        guard let raw = draft.diagnosticJSON, let data = DiagnosticJSON.withoutLocale(raw) else { return nil }
        return FeedbackAttachment(filename: "\(draft.kind.rawValue)-\(draft.appVersion)-\(draft.appBuild).json",
                                  contentType: "application/json", data: data)
    }

    /// MetricKit text runs over several lines and indents them: one line, single spaces, capped.
    private static func compacted(_ text: String, limit: Int) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    /// An anonymous submission (no email) whose context names the build that crashed. The message
    /// is trimmed one frame at a time, the image lines counting toward the limit but never trimmed,
    /// until the endpoint would take it, so even a very deep stack sends its crash site rather than
    /// nothing.
    static func submission(for draft: CrashReportDraft) -> FeedbackSubmission {
        let details = details(for: draft)
        let attachment = attachment(for: draft)
        var frameLimit = draft.frames.count
        while true {
            let submission = FeedbackSubmission(kind: .crash,
                                                message: message(for: draft, frameLimit: frameLimit),
                                                email: "",
                                                details: details,
                                                attachment: attachment)
            if frameLimit == 0 || FeedbackSender.fitsLimits(submission) {
                return submission
            }
            frameLimit -= 1
        }
    }
}
