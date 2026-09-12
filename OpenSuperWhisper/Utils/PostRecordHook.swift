import Foundation

/// Runs a user-configured shell command after a successful transcription, so people can wire
/// their own automations (save JSON, sync to git, trigger a script…). Opt-in.
///
/// The command runs via `/bin/sh -c`, fire-and-forget (never blocks the UI). The transcription
/// data is exposed two ways so any script can consume it:
/// - environment variables: `OSW_TEXT`, `OSW_RAW_TEXT`, `OSW_APP_BUNDLE_ID`, `OSW_AUDIO_PATH`,
///   `OSW_TIMESTAMP` (ISO 8601), `OSW_DURATION`
/// - a JSON object on stdin: `{ "text", "rawText", "bundleID", "audioPath", "timestamp", "duration" }`
enum PostRecordHook {

    /// What the hook is handed, built once and exposed both ways. Pure, so the shape a script
    /// depends on is unit-tested instead of only being exercised by launching a process.
    struct Payload {
        /// The text the user received: after the dictionary rules and any LLM cleanup.
        let text: String
        /// The same dictation as the engine produced it, before either of those. Equal to
        /// `text` when neither changed anything.
        let rawText: String
        /// The app that was frontmost when recording started — the one the text was dictated
        /// into, and the one the app-aware formatting rules were keyed off.
        let bundleID: String?
        let audioPath: String?
        let timestamp: Date
        let duration: Double

        var isoTimestamp: String { ISO8601DateFormatter().string(from: timestamp) }
        var durationString: String { String(format: "%.2f", duration) }

        var environment: [String: String] {
            [
                "OSW_TEXT": text,
                "OSW_RAW_TEXT": rawText,
                "OSW_APP_BUNDLE_ID": bundleID ?? "",
                "OSW_AUDIO_PATH": audioPath ?? "",
                "OSW_TIMESTAMP": isoTimestamp,
                "OSW_DURATION": durationString,
            ]
        }

        var json: [String: Any] {
            [
                "text": text,
                "rawText": rawText,
                "bundleID": bundleID ?? "",
                "audioPath": audioPath ?? "",
                "timestamp": isoTimestamp,
                "duration": duration,
            ]
        }
    }

    static func runIfEnabled(text: String, rawText: String, bundleID: String?,
                             audioPath: String?, timestamp: Date, duration: Double) {
        let prefs = AppPreferences.shared
        guard prefs.postRecordHookEnabled else { return }
        let command = prefs.postRecordHookCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        let payload = Payload(text: text, rawText: rawText, bundleID: bundleID,
                              audioPath: audioPath, timestamp: timestamp, duration: duration)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        var env = ProcessInfo.processInfo.environment
        for (key, value) in payload.environment {
            env[key] = value
        }
        process.environment = env

        let stdin = Pipe()
        process.standardInput = stdin

        do {
            try process.run()
            if let json = try? JSONSerialization.data(withJSONObject: payload.json, options: [.prettyPrinted]) {
                stdin.fileHandleForWriting.write(json)
            }
            try? stdin.fileHandleForWriting.close()
        } catch {
            print("Post-record hook failed to launch: \(error)")
        }
    }
}
