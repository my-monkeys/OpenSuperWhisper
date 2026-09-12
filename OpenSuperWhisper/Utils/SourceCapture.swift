import AppKit
import ApplicationServices
import Foundation

/// Best-effort capture of "where" a dictation happened, beyond the app name: the
/// focused window's title (Accessibility) and, for supported browsers, the active
/// tab's URL (AppleScript — triggers a one-time automation permission per app).
enum SourceCapture {
    /// Title of the system-wide focused window (e.g. a browser tab or document).
    static func focusedWindowTitle() -> String? {
        // These AX calls are synchronous IPC to the frontmost app and run on the
        // main thread at record-start / menu-open; a wedged target would freeze the
        // recording hotkey without a timeout (#freeze). Bound every request, exactly
        // as FocusUtils does.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, FocusUtils.axMessagingTimeout)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success, let windowRef else { return nil }

        let window = windowRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, FocusUtils.axMessagingTimeout)
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef
        ) == .success else { return nil }

        let title = titleRef as? String
        return (title?.isEmpty == false) ? title : nil
    }

    /// How much of the text before the caret is worth carrying. Whisper's prompt window is
    /// small and the custom dictionary already spends part of it, so this takes the tail of a
    /// sentence or two rather than a document.
    static let focusedTextLimit = 240

    /// The text already written in the field being dictated into, ending at the caret.
    ///
    /// Read from the frontmost app's own element rather than the system-wide one: the
    /// system-wide element answers `kAXErrorCannotComplete` in cases where the per-app element
    /// answers fine, and there is nothing to gain from asking the more fragile of the two.
    /// Returns nil when nothing is focused (`kAXErrorNoValue`), which is the common case in a
    /// browser sitting on a page, so callers must treat absence as normal rather than a fault.
    static func focusedText() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }

        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, FocusUtils.axMessagingTimeout)

        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return nil }

        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, FocusUtils.axMessagingTimeout)

        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success, let text = valueRef as? String, !text.isEmpty else { return nil }

        return tail(of: text, upTo: caretOffset(in: element) ?? text.count)
    }

    /// Where the caret sits in the focused element, as a character offset.
    private static func caretOffset(in element: AXUIElement) -> Int? {
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeRef else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// The last `focusedTextLimit` characters before `caret`, trimmed to start on a word.
    ///
    /// Cutting mid-word would feed the model half a token as though it were a whole one, so the
    /// leading fragment is dropped when the cut lands inside a word.
    static func tail(of text: String, upTo caret: Int) -> String? {
        let end = min(max(caret, 0), text.count)
        let written = String(text.prefix(end))
        guard !written.isEmpty else { return nil }

        var slice = String(written.suffix(focusedTextLimit))
        if slice.count < written.count, let space = slice.firstIndex(where: { $0.isWhitespace }) {
            slice = String(slice[slice.index(after: space)...])
        }

        let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// AppleScript to read the active tab/document URL, keyed by bundle id.
    private static let browserScripts: [String: String] = [
        "com.google.Chrome": "tell application \"Google Chrome\" to return URL of active tab of front window",
        "com.google.Chrome.beta": "tell application \"Google Chrome Beta\" to return URL of active tab of front window",
        "com.brave.Browser": "tell application \"Brave Browser\" to return URL of active tab of front window",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to return URL of active tab of front window",
        "com.vivaldi.Vivaldi": "tell application \"Vivaldi\" to return URL of active tab of front window",
        "company.thebrowser.Browser": "tell application \"Arc\" to return URL of active tab of front window",
        "com.apple.Safari": "tell application \"Safari\" to return URL of front document",
    ]

    /// Active-tab URL for a known browser bundle id, or nil (not a browser, no
    /// window, or automation permission denied). Synchronous — call on the main
    /// thread (NSAppleScript requirement).
    static func browserURL(bundleID: String) -> String? {
        guard let source = browserScripts[bundleID],
              let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let url = result.stringValue
        return (url?.isEmpty == false) ? url : nil
    }

    /// Host of a URL string, "www." stripped — e.g. "github.com". For display and
    /// (later) per-site rules.
    static func host(of urlString: String?) -> String? {
        guard let urlString,
              let host = URLComponents(string: urlString)?.host,
              !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
