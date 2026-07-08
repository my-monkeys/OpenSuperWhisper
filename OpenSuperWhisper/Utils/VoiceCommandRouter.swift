import AppKit
import Foundation

/// Parses (and executes) spoken voice commands, the single home for command-vs-dictation logic.
///
/// Two kinds:
///  - A leading **wake word** ("whisper open slack") routes the rest as an app command (open /
///    focus / quit) and is performed instead of being typed. Opt-in via `voiceCommandsEnabled`.
///  - A trailing **"press enter"** submits after insertion (folded in from the old
///    `stripSubmitCommand`; the pure parse lives here, the pref gate stays in `AppPreferences`).
///
/// The classification/parse functions are pure (no I/O) so they're unit-tested; `execute` does the
/// disk scan + AppKit side effects.
enum VoiceCommandRouter {

    enum AppAction: Equatable { case activate, quit }

    struct AppCommand: Equatable {
        let action: AppAction
        let query: String   // spoken app name, e.g. "slack"
    }

    /// What the router decided the utterance is.
    enum Outcome: Equatable {
        case command(AppCommand)   // wake word + recognized verb + app name
        case unrecognized          // wake word present but nothing parseable → user feedback
        case dictation             // not a command → normal insertion path
    }

    // Verb phrases mapped to an action. Multi-word phrases are matched as written.
    private static let quitVerbs = ["quit", "close", "kill", "exit"]
    private static let activateVerbs = ["switch to", "go to", "bring up", "pull up",
                                        "open", "launch", "start", "focus", "show"]

    // MARK: - Classification (pure)

    /// Classifies `text` against the configured `trigger`. Pure; no I/O.
    static func classify(_ text: String, trigger: String) -> Outcome {
        guard let remainder = stripWakeWord(text, trigger: trigger) else { return .dictation }
        guard let command = parseAppCommand(remainder) else { return .unrecognized }
        return .command(command)
    }

    /// The text after a leading `trigger` word (consuming a trailing comma/space), or nil if the
    /// utterance doesn't start with the trigger as a whole word, or is *only* the trigger.
    static func stripWakeWord(_ text: String, trigger: String) -> String? {
        let t = trigger.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let pattern = "^\\s*\(NSRegularExpression.escapedPattern(for: t))\\b[\\s,]*"
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let rest = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// Parses a command remainder ("open slack") into an `AppCommand`, or nil if no verb matches.
    static func parseAppCommand(_ remainder: String) -> AppCommand? {
        for verb in quitVerbs {
            if let query = appQuery(after: verb, in: remainder) { return AppCommand(action: .quit, query: query) }
        }
        for verb in activateVerbs {
            if let query = appQuery(after: verb, in: remainder) { return AppCommand(action: .activate, query: query) }
        }
        return nil
    }

    /// The non-empty app name following `verb` at the start of `text`, or nil.
    private static func appQuery(after verb: String, in text: String) -> String? {
        let pattern = "^\(NSRegularExpression.escapedPattern(for: verb))\\b\\s*"
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        // Trim surrounding whitespace AND punctuation: speech-to-text appends a period to short
        // utterances ("open safari." → "safari."), which would otherwise break the app match.
        let app = String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return app.isEmpty ? nil : app
    }

    /// Trailing "press enter" → (text without it, submit: true). Pure; gate on the pref at the call
    /// site (see `AppPreferences.stripSubmitCommand`).
    static func parseSubmitCommand(_ text: String) -> (text: String, submit: Bool) {
        let pattern = "[\\s,]*press[\\s,]+enter[\\s\\p{P}]*$"
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return (text, false)
        }
        return (String(text[..<range.lowerBound]), true)
    }

    // MARK: - Execution (side effects)

    /// Resolves the command's app and performs it, returning a short feedback string for the indicator.
    static func execute(_ command: AppCommand) async -> String {
        let apps = InstalledApps.all()
        guard let app = InstalledApps.bestMatch(forSpokenName: command.query, in: apps) else {
            return "No app named “\(command.query)”"
        }
        switch command.action {
        case .activate:
            await MainActor.run {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: app.url, configuration: config, completionHandler: nil)
            }
            return "Opening \(app.name)…"
        case .quit:
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
            guard !running.isEmpty else { return "\(app.name) isn't running" }
            await MainActor.run { running.forEach { $0.terminate() } }
            return "Quitting \(app.name)…"
        }
    }
}
