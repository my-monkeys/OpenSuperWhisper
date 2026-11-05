import AppKit
import ApplicationServices

/// What the focused field holds on either side of the caret, read just before a dictation is
/// inserted so the text can be fitted to it (#163). Held for that one insertion, never stored.
struct TextAroundCaret: Equatable {
    /// The end of the text before the selection, up to `contextLength`.
    let before: String
    /// What the insertion will replace: empty for a plain caret.
    let selected: String
    /// The start of the text after the selection, up to `lookaheadLength`.
    let after: String

    /// Enough to see the sentence the caret is in, and the capitalised words around it. The
    /// field can be a whole document, and nothing further away says anything about the caret.
    static let contextLength = 2_000
    static let lookaheadLength = 400

    init(before: String, selected: String = "", after: String = "") {
        self.before = before
        self.selected = selected
        self.after = after
    }

    /// Splits a field's value at the selection Accessibility reports, which counts UTF-16 units.
    /// nil when the range does not fit the value: an app whose two answers disagree is not one
    /// whose caret can be trusted.
    init?(value: String, selection: NSRange) {
        let text = value as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              NSMaxRange(selection) <= text.length else { return nil }

        // The far ends of the window are aligned on whole characters, so an emoji at the edge
        // is dropped rather than torn in half. The near ends are the caret, already a boundary.
        var start = max(0, selection.location - Self.contextLength)
        if start > 0 {
            let straddling = text.rangeOfComposedCharacterSequence(at: start)
            if straddling.location < start { start = min(straddling.upperBound, selection.location) }
        }
        var end = min(text.length, NSMaxRange(selection) + Self.lookaheadLength)
        if end < text.length { end = max(text.rangeOfComposedCharacterSequence(at: end).location, NSMaxRange(selection)) }

        self.init(before: text.substring(with: NSRange(location: start, length: selection.location - start)),
                  selected: text.substring(with: selection),
                  after: text.substring(with: NSRange(location: NSMaxRange(selection),
                                                      length: end - NSMaxRange(selection))))
    }

    /// The part of a field of `length` UTF-16 units worth asking for: the selection with the
    /// context on either side, plus `edgeMargin`. nil when the selection does not fit.
    static func window(around selection: NSRange, length: Int) -> NSRange? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              NSMaxRange(selection) <= length else { return nil }
        let start = max(0, selection.location - contextLength - edgeMargin)
        let end = min(length, NSMaxRange(selection) + lookaheadLength + edgeMargin)
        return NSRange(location: start, length: end - start)
    }

    /// A few units past each end of the window, so the cut in `init(value:selection:)` still
    /// sees the characters it lands next to and drops one it would split, exactly as it does on
    /// the whole value.
    static let edgeMargin = 16

    /// Splits the part of a field that `window(around:length:)` asked for, which starts `start`
    /// units into the field.
    init?(window text: String, at start: Int, selection: NSRange) {
        self.init(value: text, selection: NSRange(location: selection.location - start, length: selection.length))
    }

    /// The focused field of the app in front, or nil when it will not give both its text and
    /// its selection. Electron apps often keep their text to themselves, and a browser page with
    /// no field focused has none: the dictation then goes in exactly as it did before.
    ///
    /// Only the window around the selection is fetched when the field can give a range of its
    /// text: the whole value of a long document, or of a terminal and its scrollback, would be
    /// copied across processes to keep a few thousand characters of it.
    ///
    /// Our own windows are never asked: the request would be answered by this main thread,
    /// which is busy asking it.
    @MainActor
    static func focused() -> TextAroundCaret? {
        guard AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }

        let ax = TimedAccessibility(budget: .seconds(Double(FocusUtils.axMessagingTimeout)))
        guard let focused = ax.copy(kAXFocusedUIElementAttribute,
                                    of: AXUIElementCreateApplication(front.processIdentifier)),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return read(focused as! AXUIElement, with: ax)
    }

    @MainActor
    private static func read(_ element: AXUIElement, with ax: TimedAccessibility) -> TextAroundCaret? {
        // One request for all three: each round trip to a slow app costs time on the main thread.
        // The subrole comes along for the same reason, and a secure field is refused before its
        // text is asked for.
        guard let answers = ax.copy([kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute,
                                     kAXSubroleAttribute], of: element),
              answers.count == 3, let selection = range(from: answers[0]),
              !SecureTextFields.isSecure(answers[2] as? String) else { return nil }

        if let length = answers[1] as? Int, let window = window(around: selection, length: length) {
            var cfWindow = CFRange(location: window.location, length: window.length)
            if let parameter = AXValueCreate(.cfRange, &cfWindow),
               let text = ax.copy(kAXStringForRangeParameterizedAttribute, for: parameter, of: element) as? String,
               (text as NSString).length == window.length {
                return TextAroundCaret(window: text, at: window.location, selection: selection)
            }
        }
        // No range of the text on offer, or one that disagrees with the length: the whole value,
        // which `init(value:selection:)` checks against the selection.
        guard let value = ax.copy(kAXValueAttribute, of: element) as? String else { return nil }
        return TextAroundCaret(value: value, selection: selection)
    }

    private static func range(from value: CFTypeRef) -> NSRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

/// Accessibility requests that share one messaging timeout. Each gets what is left of it, and
/// the first one the app lets time out ends the read: every later one is skipped. So reading
/// the field adds at most one `FocusUtils.axMessagingTimeout` to the main thread's wait, however
/// many requests it takes.
@MainActor
private final class TimedAccessibility {
    private let deadline: ContinuousClock.Instant
    private var timedOut = false

    init(budget: Duration) {
        deadline = .now + budget
    }

    func copy(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = request(element) { AXUIElementCopyAttributeValue(element, attribute as CFString, &value) }
        return error == .success ? value : nil
    }

    /// The answers in order. One the app could not give is an `AXValue` holding its error.
    func copy(_ attributes: [String], of element: AXUIElement) -> [CFTypeRef]? {
        var values: CFArray?
        let error = request(element) {
            AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray,
                                                   AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        }
        return error == .success ? values as? [CFTypeRef] : nil
    }

    func copy(_ attribute: String, for parameter: CFTypeRef, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = request(element) {
            AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
        }
        return error == .success ? value : nil
    }

    /// `cannotComplete` is what a request that timed out returns.
    private func request(_ element: AXUIElement, _ send: () -> AXError) -> AXError {
        guard !timedOut else { return .cannotComplete }
        let left = deadline - .now
        guard left > .zero else {
            timedOut = true
            return .cannotComplete
        }
        AXUIElementSetMessagingTimeout(element, Float(left / .seconds(1)))
        let error = send()
        if error == .cannotComplete { timedOut = true }
        return error
    }
}
