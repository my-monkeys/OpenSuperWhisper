import AppKit
import KeyboardShortcuts
import SwiftUI

/// Who is talking: the agent's own icon, tucked against OpenSuperWhisper's, the two of them
/// working together. The agent's icon comes from its desktop app when it is installed, so the
/// mark is the one the user already knows and nothing of theirs ships in this bundle; without
/// it, a symbol in the agent's colour stands in.
struct AgentAvatar: View {
    var kind: AgentKind = .claudeCode

    @MainActor private static var icons: [AgentKind: NSImage] = [:]

    @MainActor static func icon(for kind: AgentKind) -> NSImage? {
        if let cached = icons[kind] { return cached }
        guard let id = kind.iconBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[kind] = image
        return image
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            // Its own rounded square, as is: a shadow is enough to lift it off the other one.
            agent(size: 22)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .offset(x: 9, y: 5)
        }
        .frame(width: 46, height: 40, alignment: .topLeading)
    }

    @ViewBuilder private func agent(size: CGFloat) -> some View {
        if let icon = Self.icon(for: kind) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            // Drawn to the avatar's size rather than as text: it is a mark, not something to read.
            Image(systemName: Self.fallbackSymbol(kind))
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(size * 0.27)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.24).fill(Self.fallbackColor(kind)))
        }
    }

    private static func fallbackSymbol(_ kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "sparkles"
        case .cursor: return "cursorarrow"
        case .unknown: return "terminal"
        }
    }

    private static func fallbackColor(_ kind: AgentKind) -> Color {
        switch kind {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(white: 0.12)
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cursor: return Color(white: 0.2)
        case .unknown: return Color.gray
        }
    }
}

/// The shortcut hints under the composer, read from the user's own bindings.
struct AgentShortcutHints {
    let keys: String
    let action: String

    /// The user's own stop-and-submit binding, spelled out; nil when they have none.
    @MainActor static func submitKeys() -> String? {
        let prefs = AppPreferences.shared
        let submit = RecordingTrigger.resolve(
            mouseRaw: prefs.submitMouseButtonHotkey,
            modifierRaw: prefs.submitModifierOnlyHotkey,
            shortcut: KeyboardShortcuts.getShortcut(for: .toggleRecordAndSubmit))
        return ModifierChord(storageValue: prefs.submitModifierChord).map { $0.symbols.joined() }
            ?? (submit == .none ? nil : submit.caps.joined(separator: " "))
    }

    @MainActor static func current(listening: Bool) -> [AgentShortcutHints] {
        let prefs = AppPreferences.shared
        let trigger = RecordingTriggerSet.load(from: prefs.recordingTriggers).triggers.first
            .map { $0.caps.joined(separator: " ") }
        var hints: [AgentShortcutHints] = []
        if listening {
            if let trigger { hints.append(.init(keys: trigger, action: "stop")) }
            // Return stands in for a stop-and-submit binding the user has not set up.
            hints.append(.init(keys: submitKeys() ?? "⏎", action: "stop and send"))
            hints.append(.init(keys: "esc", action: "delete"))
        } else {
            if let trigger { hints.append(.init(keys: trigger, action: "dictate")) }
            hints.append(.init(keys: "⏎", action: "send"))
            hints.append(.init(keys: "⇧⏎", action: "new line"))
        }
        return hints
    }
}
