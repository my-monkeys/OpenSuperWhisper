import ApplicationServices
import CoreGraphics

/// The geometry questions the caret anchor asks the focused text element, one at a time.
///
/// A protocol so the decision can run against geometry recorded from real apps instead of a
/// live Accessibility target. Rects are in AX (Quartz, top-left origin) coordinates.
protocol TextElementGeometry {
    /// What the element answers to `AXBoundsForRange` for `range`, or nil when it refuses.
    func bounds(of range: CFRange) -> CGRect?
    /// The element's own frame, or nil when it does not report one.
    var frame: CGRect? { get }
}

/// Where the bubble anchors in "cursor" mode, chosen from what the focused text element reports.
enum CaretAnchor {

    /// Which of the element's answers the anchor came from, for the diagnostic log.
    enum Source: String {
        case caret
        case characterBefore
    }

    struct Choice: Equatable {
        let rect: CGRect
        let source: Source
    }

    /// Picks the anchor for `selection`, asking `element` only what it needs to.
    ///
    /// In order:
    /// 1. The caret itself, when it has height. A successful bounds query is not a believable one:
    ///    Chrome answers with an empty rect at a corner of the primary display (#143). Where a
    ///    caret with height sits is not second-guessed: TextEdit reports a valid one above its
    ///    text view's own frame.
    /// 2. The trailing edge of the character just before the caret. Terminal.app answers the caret
    ///    query with an empty rect at a meaningless position, but places the character before it
    ///    on the prompt line (#155).
    ///
    /// Anything else follows the mouse. The field itself is no anchor: Chromium apps answer with
    /// empty carets, and the field they report is often not where the typing is. Dia reported
    /// its whole window, then a field 176 pt above the top of the screen, and both put the bubble
    /// at the top-left of the screen. Ghostty's field is a whole terminal surface (#155). Whoever
    /// dictates into a field has usually just clicked it, so the pointer is close.
    ///
    /// An app with a real caret is asked one question, and the frame is only asked to check a
    /// character. nil when nothing usable comes back, leaving the caller to fall back to the mouse.
    static func choose(selection: CFRange, in element: TextElementGeometry) -> Choice? {
        let caret = element.bounds(of: selection)
        if let caret, caret.height > 0 {
            return Choice(rect: caret, source: .caret)
        }
        guard let character = characterBefore(selection, in: element) else { return nil }
        let field = element.frame.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        return trailingEdge(of: character, field: field).map { Choice(rect: $0, source: .characterBefore) }
    }

    /// The bounds of the character just before the selection, when they have height.
    ///
    /// Only the character before: at the start of the text there is nothing to measure, and the
    /// character after is no substitute, because Ghostty reports its caret at offset 0 whenever
    /// nothing is selected, and the first character of its scrollback is nowhere near the prompt.
    ///
    /// With the caret at the start of a line, the character before is the newline that ends the
    /// line above, and the bubble goes to the end of that line: one line off, in the right
    /// field. Telling a newline apart would take reading the text or guessing from where its
    /// rect ends, and no app has been recorded answering for one yet.
    private static func characterBefore(_ selection: CFRange,
                                        in element: TextElementGeometry) -> CGRect? {
        guard selection.location > 0 else { return nil }
        let before = CFRange(location: selection.location - 1, length: 1)
        guard let character = element.bounds(of: before), character.height > 0 else { return nil }
        return character
    }

    /// A zero-width caret where `character` ends, or nil when that is no more believable than the
    /// caret was.
    ///
    /// A character with height can still be in the wrong place, as Chrome's caret was (#143): in
    /// another coordinate space, or scrolled out of view, like a Terminal selection that starts in
    /// the scrollback. Its end must lie in the field, give or take a line, which also allows for
    /// text reported just outside its view's frame as TextEdit's caret is. A "character" covering
    /// the whole field is the field: Chrome answers the sibling text-marker query with the entire
    /// editor (#143), and its trailing edge would put the bubble past the field's far side.
    private static func trailingEdge(of character: CGRect, field: CGRect?) -> CGRect? {
        let edge = CGRect(x: character.maxX, y: character.minY, width: 0, height: character.height)
        guard let field else { return edge }
        let slack = character.height
        guard !character.contains(field),
              field.insetBy(dx: -slack, dy: -slack).contains(CGPoint(x: edge.minX, y: edge.midY))
        else { return nil }
        return edge
    }
}

/// The live element behind `TextElementGeometry`. Every answer goes to the diagnostic log, rects
/// and offsets only, never text, so an app that misplaces the bubble can be turned into a test
/// fixture from `log show`.
struct AXTextElementGeometry: TextElementGeometry {
    let element: AXUIElement

    func bounds(of range: CFRange) -> CGRect? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var answer: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element,
                                                               kAXBoundsForRangeParameterizedAttribute as CFString,
                                                               value,
                                                               &answer)
        let rect = error == .success ? answer.flatMap(Self.rect(of:)) : nil
        Diag.mark("caret geometry: bounds(\(range.location)+\(range.length)) = \(Self.describe(rect)) (AXError \(error.rawValue))")
        return rect
    }

    var frame: CGRect? {
        let rect = Self.frame(of: element)
        Diag.mark("caret geometry: frame = \(Self.describe(rect))")
        return rect
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }

        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func rect(of value: CFTypeRef) -> CGRect? {
        let value = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return "(\(rect.minX), \(rect.minY)) \(rect.width) × \(rect.height)"
    }
}
