import AppKit
import Foundation
import OpenSuperWhisperCore

/// The logic behind the "Pick a recent dictation" panel, kept free of AppKit windows so it can
/// be tested with plain values: which rows to show, what a key press means, where the panel goes.
enum RecentPicker {

    /// Rows offered, one per digit key.
    static let rowCount = 9

    /// How many stored recordings are scanned for usable ones, as in the status bar's submenu.
    static let scanDepth = RecentTranscripts.scanDepth

    // MARK: Rows

    struct Row: Equatable, Identifiable {
        /// 1 to 9, the key that inserts it.
        let number: Int
        /// The whole transcription, what gets inserted.
        let text: String
        /// The same with whitespace runs collapsed, what the row shows.
        let preview: String
        let age: String
        var id: Int { number }
    }

    /// Rows for the newest usable dictations. Which clips are usable is [RecentTranscripts]'s
    /// call, so the panel and the status bar's "Recent" submenu always agree.
    static func rows(from recordings: [Recording], now: Date = Date(),
                     locale: Locale = .current) -> [Row] {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named  // "now" rather than "in 0 seconds"
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        return RecentTranscripts.pick(from: recordings, limit: rowCount).enumerated().map { index, recording in
            Row(number: index + 1,
                text: recording.transcription,
                preview: RecentTranscripts.menuTitle(for: recording.transcription, limit: .max),
                // A clock set back must not read "in 2 min".
                age: formatter.localizedString(for: min(recording.timestamp, now), relativeTo: now))
        }
    }

    // MARK: Keys

    enum Action: Equatable {
        /// Insert the row with this number (1 based). May be past the last row; the caller ignores it.
        case insert(number: Int)
        case moveHighlight(by: Int)
        case insertHighlighted
        case close
    }

    private static let keyCodeReturn: UInt16 = 36
    private static let keyCodeKeypadEnter: UInt16 = 76
    private static let keyCodeEscape: UInt16 = 53
    private static let keyCodeDown: UInt16 = 125
    private static let keyCodeUp: UInt16 = 126
    /// Digit 1 to 9 on the top row, then on the keypad. Physical keys, so a French AZERTY layout
    /// (digits behind Shift) inserts with the bare key like any other.
    private static let topRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let keypadKeyCodes: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// What a key press asks for, or `nil` when the panel has no use for it. Modifiers are not
    /// looked at: the shortcut that opened the panel may still be partly held.
    static func action(forKeyCode keyCode: UInt16) -> Action? {
        switch keyCode {
        case keyCodeEscape: return .close
        case keyCodeDown: return .moveHighlight(by: 1)
        case keyCodeUp: return .moveHighlight(by: -1)
        case keyCodeReturn, keyCodeKeypadEnter: return .insertHighlighted
        default:
            let digit = topRowKeyCodes.firstIndex(of: keyCode) ?? keypadKeyCodes.firstIndex(of: keyCode)
            return digit.map { .insert(number: $0 + 1) }
        }
    }

    /// The highlighted row after a step, wrapping at both ends. `current` is 0 based.
    static func highlight(after current: Int, by step: Int, rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        return ((current + step) % rowCount + rowCount) % rowCount
    }

    // MARK: Placement

    /// Distance between the caret (or mouse) and the panel's near edge.
    static let anchorGap: CGFloat = 6

    /// The panel's frame in Cocoa coordinates: under `anchor`, flipped above it when the bottom
    /// of `visible` would cut it, then kept inside `visible` on both axes.
    static func frame(size: CGSize, anchor: CGRect, visible: CGRect, gap: CGFloat = anchorGap) -> CGRect {
        var y = anchor.minY - gap - size.height
        if y < visible.minY { y = anchor.maxY + gap }
        let x = anchor.minX
        return CGRect(x: max(visible.minX, min(x, visible.maxX - size.width)),
                      y: max(visible.minY, min(y, visible.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    /// A caret rect from accessibility (top-left origin of the primary screen) as a Cocoa rect.
    static func cocoaRect(fromAX rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenMaxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
