import SwiftUI
import KeyboardShortcuts
import OpenSuperWhisperCore

/// The trigger Home talks about: the first one configured, and whether it records while held.
@MainActor
struct HomeTriggerSummary: Equatable {
    /// Compact name of the key or button, "⌥ right", "⌃⌥Space", "Button 4 (Back)".
    let label: String
    /// What the floating control draws above Hold / Press.
    let glyph: Glyph
    /// True when the recording lasts as long as the key is held.
    let holds: Bool

    enum Glyph: Equatable {
        case text(String)
        case symbol(String)
    }

    /// Same order as the old hint under the record button (mouse, modifier, shortcut), then
    /// chords, then the hold-only triggers, which always hold whatever `holdToRecord` says.
    static func resolve(triggersJSON: String, holdTriggersJSON: String, holdToRecord: Bool) -> HomeTriggerSummary? {
        let set = RecordingTriggerSet.load(from: triggersJSON)
        if let summary = first(in: set, holds: holdToRecord) { return summary }
        if let chord = set.chords.first {
            // A chord fires once, on release, so it always toggles.
            let symbols = chord.symbols.joined()
            return HomeTriggerSummary(label: symbols, glyph: .text(symbols), holds: false)
        }
        return first(in: RecordingTriggerSet.load(from: holdTriggersJSON), holds: true)
    }

    private static func first(in set: RecordingTriggerSet, holds: Bool) -> HomeTriggerSummary? {
        if let button = set.mouseButtons.first {
            return HomeTriggerSummary(label: button.displayName, glyph: .symbol("computermouse"), holds: holds)
        }
        if let key = set.modifiers.first {
            return HomeTriggerSummary(label: label(for: key), glyph: .text(key.shortSymbol), holds: holds)
        }
        if let combo = set.keyCombos.first {
            return HomeTriggerSummary(label: combo.description, glyph: .text(combo.description), holds: holds)
        }
        return nil
    }

    /// "⌥ right": the short name Home uses, and onboarding too, so both spell a key the same way.
    /// `locale` lets a view pass its own, which the snapshot probe sets per render.
    static func label(for key: ModifierKey, locale: Locale = .current) -> String {
        var name: LocalizedStringResource
        switch key {
        case .leftCommand, .leftOption, .leftShift, .leftControl:
            name = "\(key.shortSymbol) left"
        case .rightCommand, .rightOption, .rightShift, .rightControl:
            name = "\(key.shortSymbol) right"
        case .fn, .none:
            return key.shortSymbol
        }
        name.locale = locale
        return String(localized: name)
    }
}

/// Reads the trigger preferences through @AppStorage so Home follows the settings live.
struct HomeTriggerReader<Content: View>: View {
    @AppStorage("recordingTriggers", store: DefaultsStore.current) private var triggers = ""
    @AppStorage("holdRecordingTriggers", store: DefaultsStore.current) private var holdTriggers = ""
    @AppStorage("holdToRecord", store: DefaultsStore.current) private var holdToRecord = true
    @ViewBuilder let content: (HomeTriggerSummary?) -> Content

    var body: some View {
        content(HomeTriggerSummary.resolve(triggersJSON: triggers, holdTriggersJSON: holdTriggers,
                                           holdToRecord: holdToRecord))
    }
}

/// "Kept 30 days · change": how long the history is kept, from the Privacy settings.
struct RetentionSummary: View {
    @AppStorage("saveTranscriptionHistory", store: DefaultsStore.current) private var saveHistory = true
    @AppStorage("retentionMaxAgeEnabled", store: DefaultsStore.current) private var ageEnabled = false
    @AppStorage("retentionMaxAgeValue", store: DefaultsStore.current) private var ageValue = 30
    @AppStorage("retentionMaxAgeUnit", store: DefaultsStore.current) private var ageUnit = "days"
    @AppStorage("retentionMaxCountEnabled", store: DefaultsStore.current) private var countEnabled = false
    @AppStorage("retentionMaxCount", store: DefaultsStore.current) private var count = 100
    @ObservedObject private var usage = RecordingsDiskUsage.shared
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 4) {
            summary
                .foregroundColor(STheme.hint)
            if let size {
                Text(verbatim: "·")
                    .foregroundColor(STheme.hint)
                Text(verbatim: size)
                    .foregroundColor(STheme.hint)
            }
            Text(verbatim: "·")
                .foregroundColor(STheme.hint)
            Button {
                AppNavigation.shared.openSettings(.privacy)
            } label: {
                Text("change")
                    .foregroundColor(STheme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the history settings")
        }
        .scaledFont(size: 13)
        .lineLimit(1)
        .fixedSize()
        .task { await usage.loadIfNeeded() }
    }

    private var size: String? { RecordingsSizeLabel.size(usage.total, locale: locale) }

    private var ageLimited: Bool { ageEnabled && ageValue > 0 }
    private var countLimited: Bool { countEnabled && count > 0 }

    private var summary: Text {
        if !saveHistory { return Text("History off") }
        switch (ageLimited, countLimited) {
        case (true, true): return Text("Kept \(age), up to \(count)")
        case (true, false): return Text("Kept \(age)")
        case (false, true): return Text("Last \(count) kept")
        case (false, false): return Text("Kept forever")
        }
    }

    private var age: String {
        switch ageUnit {
        case "minutes": return String(AttributedString(localized: "^[\(ageValue) minute](inflect: true)").characters)
        case "hours": return String(AttributedString(localized: "^[\(ageValue) hour](inflect: true)").characters)
        default: return String(AttributedString(localized: "^[\(ageValue) day](inflect: true)").characters)
        }
    }
}
