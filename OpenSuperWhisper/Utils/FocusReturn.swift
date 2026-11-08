import AppKit
import ApplicationServices

/// How much text a field held and what was selected in it, to tell later whether it changed.
struct FieldSnapshot: Equatable {
    let characterCount: Int
    let selection: NSRange

    /// From the raw `kAXNumberOfCharacters` and `kAXSelectedTextRange` answers. nil unless both
    /// came back: a caret is only worth putting back when there is a way to tell it is still valid.
    init?(characterCount: CFTypeRef?, selection: CFTypeRef?) {
        guard let count = characterCount as? Int, let selection,
              CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range) else { return nil }
        self.init(characterCount: count, selection: NSRange(location: range.location, length: range.length))
    }

    init(characterCount: Int, selection: NSRange) {
        self.characterCount = characterCount
        self.selection = selection
    }
}

/// The field a dictation started in, kept so its text can go back there once transcribed (#164).
///
/// Transcription runs after the recording stops, and with a long clip or a slow model the user
/// has often clicked somewhere else by the time the text is ready. Held in memory with the one
/// dictation it belongs to, never written anywhere.
struct FocusTarget {
    let pid: pid_t
    /// Checked along with the pid, which the system hands to another process once the app quits.
    let bundleID: String?
    /// The focused element when the dictation started. nil when the app would not say, which is
    /// what Chrome and Electron answer while their accessibility tree is off: the app alone is
    /// then all there is to go back to.
    let element: AXUIElement?
    /// Its length and caret then, so the caret can be put back after refocusing if nothing has
    /// been written there since (see `FocusReturn.selectionToSet`).
    let field: FieldSnapshot?

    /// The focused element of `app` right now, with its caret.
    static func capture(_ app: NSRunningApplication) -> FocusTarget {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, FocusUtils.axMessagingTimeout)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let focused else {
            return FocusTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                               element: nil, field: nil)
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, FocusUtils.axMessagingTimeout)

        var count: CFTypeRef?
        var range: CFTypeRef?
        // The second question is not asked of an element that did not answer the first.
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString,
                                         &count) == .success {
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range)
        }
        return FocusTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                           element: element, field: FieldSnapshot(characterCount: count, selection: range))
    }
}

/// What putting the focus back needs from the system, behind a seam so the decision can be
/// tested without activating or focusing anything on the machine running the tests.
@MainActor
protocol FocusControlling {
    func frontmostPID() -> pid_t?
    /// The app is still the one that was captured, not a new process that inherited its pid.
    func isRunning(_ target: FocusTarget) -> Bool
    /// Whether the captured element still has the focus in its app. nil when the app would not
    /// say, which is no evidence that the user moved.
    func stillFocused(_ target: FocusTarget) -> Bool?
    /// Brings the app in front. false when the system refused.
    func activate(_ target: FocusTarget) -> Bool
    /// Brings the app in front through LaunchServices, for an app that let `activate` through
    /// and stayed behind. false when the request could not be made.
    func reopen(_ target: FocusTarget) -> Bool
    /// Raises the element's window and focuses the element. false when the element is gone or
    /// would not take the focus.
    func focus(_ target: FocusTarget) -> Bool
    /// The element's length and selection now. nil when it would not say.
    func field(_ target: FocusTarget) -> FieldSnapshot?
    func select(_ range: NSRange, in target: FocusTarget)
    /// Gives the app a moment to act on the focus change before anything is typed into it.
    func settle() async
}

/// Puts the focus back where a dictation started before its text is inserted (#164).
enum FocusReturn {

    enum Outcome: Equatable {
        /// The focus never left, or there is nothing more precise to go back to.
        case alreadyThere
        /// The field has the focus again.
        case refocused
        /// The field is gone, so only the app is back: the text goes wherever it puts the focus.
        case appOnly
        /// The app quit or would not come back. Inserting now would put the text into whatever
        /// is in front, which is exactly the wrong place.
        case unreachable
    }

    @MainActor
    static func bringBack(_ target: FocusTarget,
                          using system: FocusControlling = LiveFocusControl()) async -> Outcome {
        guard system.isRunning(target) else { return .unreachable }

        if system.frontmostPID() == target.pid {
            // Another field of the same app, or the same one: only a definite "moved" is acted
            // on, so an app that cannot answer behaves as it did before this feature.
            guard target.element != nil, system.stillFocused(target) == false else { return .alreadyThere }
            let outcome: Outcome = refocus(target, using: system) ? .refocused : .appOnly
            await system.settle()
            return outcome
        }

        guard system.activate(target) else { return .unreachable }
        let outcome: Outcome = refocus(target, using: system) ? .refocused : .appOnly
        await system.settle()
        if system.frontmostPID() == target.pid { return outcome }
        return await reopen(target, using: system)
    }

    /// The second attempt, for an app still behind after an activation the system accepted.
    ///
    /// Dia takes the accessibility request with a success and stays where it is, and the
    /// workspace request is refused to an app that is not active itself, as this one is not
    /// while it transcribes. LaunchServices brings it forward, as `open` does, in about 50 ms.
    /// It is not the first attempt because it also sends the app a reopen event, which makes an
    /// app with no window open a new one. Still behind after that, someone else is in front and
    /// the text would land there.
    @MainActor
    private static func reopen(_ target: FocusTarget, using system: FocusControlling) async -> Outcome {
        guard system.reopen(target) else { return .unreachable }
        await system.settle()
        guard system.frontmostPID() == target.pid else { return .unreachable }
        let outcome: Outcome = refocus(target, using: system) ? .refocused : .appOnly
        await system.settle()
        return outcome
    }

    @MainActor
    private static func refocus(_ target: FocusTarget, using system: FocusControlling) -> Bool {
        guard target.element != nil, system.focus(target) else { return false }
        if let range = selectionToSet(captured: target.field, now: system.field(target)) {
            system.select(range, in: target)
        }
        return true
    }

    /// Where the caret goes once the field has the focus back, or nil to leave it.
    ///
    /// The caret from record start is only valid while the field holds what it held then.
    /// Dictations queue up: a second one started in the same field before the first was
    /// inserted shares its caret, and putting that back would land the second text before the
    /// first, or replace text that has moved under a selection. So a field that changed keeps
    /// the caret it gives itself, except that a text field regaining the focus selects all of
    /// its text, which the paste would replace: that selection collapses to the end. Pure, for
    /// testing.
    static func selectionToSet(captured: FieldSnapshot?, now: FieldSnapshot?) -> NSRange? {
        guard let now else { return nil }
        if let captured, captured.characterCount == now.characterCount {
            return captured.selection == now.selection ? nil : captured.selection
        }
        let everything = NSRange(location: 0, length: now.characterCount)
        return now.characterCount > 0 && now.selection == everything
            ? NSRange(location: now.characterCount, length: 0) : nil
    }
}

/// The real system, through Accessibility and the workspace.
///
/// One instance serves one delivery, on the main actor, where the hotkey tap also runs. A
/// target that does not answer would otherwise cost the full messaging timeout on each of the
/// half dozen requests a refocus makes, so the first request it lets time out ends the attempt:
/// every later one is skipped and reports failure. A delivery therefore blocks the main thread
/// for at most one `FocusUtils.axMessagingTimeout`, as the single editability check before it
/// did, plus one more when "Match the text around the cursor" reads the field afterwards
/// (`TextAroundCaret.focused`, which keeps to a single timeout the same way).
@MainActor
final class LiveFocusControl: FocusControlling {

    /// Long enough for an activated app to bring its window forward and hand the field the
    /// focus, short enough not to be noticed on top of the transcription itself.
    static let settleDelay: Duration = .milliseconds(200)

    private var unresponsive = false

    nonisolated init() {}

    func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func isRunning(_ target: FocusTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            return false
        }
        return app.bundleIdentifier == target.bundleID
    }

    func stillFocused(_ target: FocusTarget) -> Bool? {
        guard let element = target.element else { return nil }
        var focused: CFTypeRef?
        let err = copy(kAXFocusedUIElementAttribute, of: AXUIElementCreateApplication(target.pid), into: &focused)
        guard err == .success, let focused else {
            // Nothing focused at all is an answer: the user clicked off the field.
            return FocusUtils.reportsNothingFocused(err) ? false : nil
        }
        return CFEqual(focused, element)
    }

    /// Through Accessibility first: since macOS 14 activation is cooperative, and an app that is
    /// not active itself (which OpenSuperWhisper is not, while it transcribes in the background)
    /// has nothing to yield. The workspace request is the fallback when the app refuses the
    /// accessibility one, and asks nothing of the app itself.
    func activate(_ target: FocusTarget) -> Bool {
        let app = AXUIElementCreateApplication(target.pid)
        if set(kAXFrontmostAttribute, of: app, to: kCFBooleanTrue) == .success { return true }
        return NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) ?? false
    }

    func reopen(_ target: FocusTarget) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: target.pid)?.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        return true
    }

    func focus(_ target: FocusTarget) -> Bool {
        guard let element = target.element else { return false }
        raiseWindow(of: element)
        return set(kAXFocusedAttribute, of: element, to: kCFBooleanTrue) == .success
    }

    func field(_ target: FocusTarget) -> FieldSnapshot? {
        guard let element = target.element else { return nil }
        var count: CFTypeRef?
        var range: CFTypeRef?
        guard copy(kAXNumberOfCharactersAttribute, of: element, into: &count) == .success else { return nil }
        copy(kAXSelectedTextRangeAttribute, of: element, into: &range)
        return FieldSnapshot(characterCount: count, selection: range)
    }

    func select(_ range: NSRange, in target: FocusTarget) {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let element = target.element, let value = AXValueCreate(.cfRange, &cfRange) else { return }
        set(kAXSelectedTextRangeAttribute, of: element, to: value)
    }

    func settle() async {
        try? await Task.sleep(for: Self.settleDelay)
    }

    /// The field may sit in another window of the app than the one in front now, and focusing
    /// an element does not bring its window forward.
    private func raiseWindow(of element: AXUIElement) {
        var windowRef: CFTypeRef?
        guard copy(kAXWindowAttribute, of: element, into: &windowRef) == .success, let windowRef else { return }
        let window = windowRef as! AXUIElement
        set(kAXMainAttribute, of: window, to: kCFBooleanTrue)
        guard !unresponsive else { return }
        AXUIElementSetMessagingTimeout(window, FocusUtils.axMessagingTimeout)
        note(AXUIElementPerformAction(window, kAXRaiseAction as CFString))
    }

    @discardableResult
    private func copy(_ attribute: String, of element: AXUIElement, into value: inout CFTypeRef?) -> AXError {
        guard !unresponsive else { return .cannotComplete }
        AXUIElementSetMessagingTimeout(element, FocusUtils.axMessagingTimeout)
        return note(AXUIElementCopyAttributeValue(element, attribute as CFString, &value))
    }

    @discardableResult
    private func set(_ attribute: String, of element: AXUIElement, to value: CFTypeRef) -> AXError {
        guard !unresponsive else { return .cannotComplete }
        AXUIElementSetMessagingTimeout(element, FocusUtils.axMessagingTimeout)
        return note(AXUIElementSetAttributeValue(element, attribute as CFString, value))
    }

    /// `cannotComplete` is what a request that timed out returns.
    @discardableResult
    private func note(_ error: AXError) -> AXError {
        if error == .cannotComplete { unresponsive = true }
        return error
    }
}
