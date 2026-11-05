import AppKit
import ApplicationServices
import OpenSuperWhisperCore

/// The one field a dictation went into, read again and again while the user may be correcting
/// it (#169).
///
/// Every request here is made off the main thread, unlike `TextAroundCaret` which reads once,
/// right before an insertion, where the main thread has to wait for the answer anyway. A watch
/// asks twice a second for up to a minute, and the hotkey tap that starts the next recording
/// runs on the main run loop: a slow app must never be able to stall it.
///
/// Holds the element, never a copy of the text: what is read is handed back to the caller and
/// kept in memory for the length of the watch.
struct WatchedField: @unchecked Sendable {
    // AXUIElement is a CFType: safe to retain and use from any thread, just not marked Sendable.
    let element: AXUIElement
    let pid: pid_t

    /// Shorter than `FocusUtils.axMessagingTimeout`: nothing waits on these, and a field that
    /// cannot answer in a quarter of a second is one to give up on rather than wait for.
    static let timeout: Float = 0.25

    /// Its length and selection, which change with every edit: the text is read only when they
    /// moved.
    struct State: Equatable {
        let length: Int
        let selection: NSRange
    }

    /// The focused field of `pid`, or nil when there is none or it is a password field.
    static func focused(in pid: pid_t) -> WatchedField? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        let field = WatchedField(element: element, pid: pid)
        // A secure field reports bullets or nothing, but it is not ours to ask in the first place.
        guard !SecureTextFields.isSecure(field.string(kAXSubroleAttribute)) else { return nil }
        return field
    }

    /// Whether this element still has the focus in its app. nil when the app would not say.
    func hasFocus() -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard error == .success, let focused else {
            return FocusUtils.reportsNothingFocused(error) ? false : nil
        }
        return CFEqual(focused, element)
    }

    func state() -> State? {
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        var values: CFArray?
        let attributes = [kAXNumberOfCharactersAttribute, kAXSelectedTextRangeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let answers = values as? [CFTypeRef], answers.count == 2,
              let length = answers[0] as? Int,
              let selection = Self.range(from: answers[1]) else { return nil }
        return State(length: length, selection: selection)
    }

    /// The text in `range`, through a range request where the field offers one, else cut from
    /// its whole value when that is not too long to copy across. nil when neither works.
    func text(in range: NSRange, fieldLength: Int) -> String? {
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        var cfRange = CFRange(location: range.location, length: range.length)
        if let parameter = AXValueCreate(.cfRange, &cfRange) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                          parameter, &value) == .success,
               let text = value as? String, (text as NSString).length == range.length {
                return text
            }
        }
        guard fieldLength <= Self.maxWholeValue, let value = string(kAXValueAttribute) else { return nil }
        let whole = value as NSString
        guard NSMaxRange(range) <= whole.length else { return nil }
        return whole.substring(with: range)
    }

    /// The whole value of a document is not copied twice a second to keep a few lines of it.
    static let maxWholeValue = 20_000

    private func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func range(from value: CFTypeRef) -> NSRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
