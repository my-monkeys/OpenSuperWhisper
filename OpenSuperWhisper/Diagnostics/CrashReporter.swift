import AppKit
import MetricKit
import OpenSuperWhisperCore

/// Receives crash and hang diagnostics from MetricKit on the launch after they happened, and,
/// depending on the person's choice, discards them, sends them, or asks first.
///
/// MetricKit hands these over on a background queue early in a launch, already free of anything
/// that identifies the person: a call stack, the exception, the build and the OS. `CrashReport`
/// turns one into the same message the Feedback card would send, and it goes to the same endpoint.
@MainActor
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    /// What to do with a batch of drafts, from the stored mode alone.
    enum Action: Equatable {
        case discard
        case send
        case ask
    }

    nonisolated static func action(for mode: CrashReportMode) -> Action {
        switch mode {
        case .off: return .discard
        case .auto: return .send
        case .ask: return .ask
        }
    }

    private let mode: () -> CrashReportMode
    private let sender: FeedbackSender
    private var started = false

    init(mode: @escaping () -> CrashReportMode = { AppPreferences.shared.crashReportMode },
         sender: FeedbackSender = FeedbackSender()) {
        self.mode = mode
        self.sender = sender
        super.init()
    }

    /// Subscribes to MetricKit. Safe to call more than once; only the first takes effect.
    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    // MARK: - MXMetricManagerSubscriber

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let drafts = payloads.flatMap(CrashReporter.drafts(from:))
        guard !drafts.isEmpty else { return }
        Task { @MainActor in self.handle(drafts) }
    }

    private func handle(_ drafts: [CrashReportDraft]) {
        switch Self.action(for: mode()) {
        case .discard:
            return
        case .send:
            drafts.forEach(send)
        case .ask:
            ask(about: drafts)
        }
    }

    private func send(_ draft: CrashReportDraft) {
        let submission = CrashReport.submission(for: draft)
        Task { try? await sender.send(submission) }
    }

    /// One alert for the batch, after a short settle so it is not the first thing on screen. "Send"
    /// sends every pending draft; "Never" turns reporting off for this Mac; "Not now" drops them,
    /// since MetricKit does not hand the same one back.
    private func ask(about drafts: [CrashReportDraft]) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let alert = NSAlert()
            alert.messageText = String(localized: "OpenSuperWhisper closed unexpectedly")
            alert.informativeText = String(localized: """
            Send a report so this gets fixed? It contains where the app stopped, its version and \
            your macOS version. It does not contain your dictations, your audio or your clipboard.
            """)
            alert.addButton(withTitle: String(localized: "Send Report"))
            alert.addButton(withTitle: String(localized: "Not Now"))
            alert.addButton(withTitle: String(localized: "Never Send"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                drafts.forEach(self.send)
            case .alertThirdButtonReturn:
                AppPreferences.shared.crashReportMode = .off
            default:
                break
            }
        }
    }

    // MARK: - MetricKit → draft

    private static func drafts(from payload: MXDiagnosticPayload) -> [CrashReportDraft] {
        let crashes = (payload.crashDiagnostics ?? []).map { draft(from: $0) }
        let hangs = (payload.hangDiagnostics ?? []).map { draft(from: $0) }
        return crashes + hangs
    }

    private static func draft(from crash: MXCrashDiagnostic) -> CrashReportDraft {
        let stack = parsedStack(of: crash.callStackTree)
        return CrashReportDraft(kind: .crash, cause: cause(of: crash), frames: stack.frames, images: stack.images,
                                memoryRegion: crash.virtualMemoryRegionInfo,
                                exceptionReason: crash.exceptionReason.map {
                                    CrashReport.exceptionReason(name: $0.exceptionName, className: $0.className,
                                                                message: $0.composedMessage)
                                },
                                diagnosticJSON: crash.jsonRepresentation(),
                                appVersion: crash.applicationVersion, appBuild: crash.metaData.applicationBuildVersion,
                                osVersion: crash.metaData.osVersion)
    }

    private static func draft(from hang: MXHangDiagnostic) -> CrashReportDraft {
        let stack = parsedStack(of: hang.callStackTree)
        return CrashReportDraft(kind: .hang, cause: "hang for \(hang.hangDuration.value) \(hang.hangDuration.unit.symbol)",
                                frames: stack.frames, images: stack.images,
                                diagnosticJSON: hang.jsonRepresentation(),
                                appVersion: hang.applicationVersion, appBuild: hang.metaData.applicationBuildVersion,
                                osVersion: hang.metaData.osVersion)
    }

    private static func cause(of crash: MXCrashDiagnostic) -> String {
        var parts: [String] = []
        if let type = crash.exceptionType { parts.append("exception \(type)") }
        if let code = crash.exceptionCode { parts.append("code \(code)") }
        if let signal = crash.signal { parts.append("signal \(signal)") }
        if let reason = crash.terminationReason, !reason.isEmpty { parts.append(reason) }
        return parts.isEmpty ? "crash" : parts.joined(separator: " · ")
    }

    private static func parsedStack(of tree: MXCallStackTree) -> ParsedCallStack {
        CallStackTree.parse(tree.jsonRepresentation())
    }
}
