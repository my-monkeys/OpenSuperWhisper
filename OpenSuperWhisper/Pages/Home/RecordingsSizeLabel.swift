import SwiftUI
import OpenSuperWhisperCore

/// The wording of the recordings' weight (#278), kept apart from the views so it can be tested.
enum RecordingsSizeLabel {
    /// "7.7 GB": the Home line, after the retention summary. Nil while nothing was counted
    /// yet, or when there is nothing to weigh, so no view ever shows "0 bytes".
    static func size(_ total: RecordingsDiskUsage.Total?, locale: Locale = .current) -> String? {
        guard let total, total.count > 0 else { return nil }
        return RecordingsDiskUsage.sizeLabel(bytes: total.bytes, locale: locale)
    }

    /// "7.7 GB · 11,664 recordings": the Privacy line, beside "Show in Finder".
    static func sizeAndCount(_ total: RecordingsDiskUsage.Total?, locale: Locale = .current) -> String? {
        guard let size = size(total, locale: locale), let total else { return nil }
        let count = String(AttributedString(localized: "^[\(total.count) recording](inflect: true)",
                                            locale: locale).characters)
        return "\(size) · \(count)"
    }
}

/// Counts the recordings folder the first time a view shows it, then follows the store.
struct RecordingsSizeText: View {
    enum Style { case size, sizeAndCount }

    let style: Style
    @ObservedObject private var usage = RecordingsDiskUsage.shared
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if let text { Text(verbatim: text) }
        }
        .task {
            if style == .sizeAndCount { await usage.refresh() } else { await usage.loadIfNeeded() }
        }
    }

    private var text: String? {
        switch style {
        case .size: return RecordingsSizeLabel.size(usage.total, locale: locale)
        case .sizeAndCount: return RecordingsSizeLabel.sizeAndCount(usage.total, locale: locale)
        }
    }
}
