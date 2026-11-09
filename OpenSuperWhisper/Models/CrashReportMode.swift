import Foundation

/// What the app does with a crash or hang report once MetricKit hands one over on the next launch.
///
/// A report says where the app stopped, never what it was transcribing: the call stack, the app
/// version, the OS. It leaves out the dictation, the audio and the clipboard. The choice is still
/// the person's, because a stack trace leaves this Mac either way, so the default asks.
enum CrashReportMode: String, Codable, CaseIterable, Identifiable {
    /// Ask on the next launch, once per pending report, with what it contains in front of the
    /// person before anything is sent.
    case ask
    /// Send without asking. For someone who has seen one and would rather not be interrupted again.
    case auto
    /// Keep nothing and send nothing.
    case off

    var id: String { rawValue }

    /// The mode a fresh install starts on, and the fallback for an unreadable stored value.
    static let `default`: CrashReportMode = .ask

    static func resolve(_ rawValue: String?) -> CrashReportMode {
        rawValue.flatMap(CrashReportMode.init(rawValue:)) ?? .default
    }

    var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .auto: return "Send automatically"
        case .off: return "Never send"
        }
    }
}
