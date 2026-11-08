import CoreGraphics
@testable import OpenSuperWhisper

/// A focused text element replayed from what an app answered, in AX (top-left origin)
/// coordinates. Records every question asked, so a test can also pin down how many Accessibility
/// round trips the anchor costs: each one is IPC to the frontmost app on the key-down path.
final class RecordedTextElement: TextElementGeometry {
    let name: String
    let selection: CFRange
    private let boundsAnswers: [String: CGRect]
    private let frameAnswer: CGRect?
    private(set) var asked: [String] = []

    /// `bounds` maps "location+length" to the rect the app returned; a range missing from it is
    /// one the app refused.
    init(_ name: String, selection: CFRange, bounds: [String: CGRect], frame: CGRect?) {
        self.name = name
        self.selection = selection
        self.boundsAnswers = bounds
        self.frameAnswer = frame
    }

    func bounds(of range: CFRange) -> CGRect? {
        let key = "\(range.location)+\(range.length)"
        asked.append("bounds(\(key))")
        return boundsAnswers[key]
    }

    var frame: CGRect? {
        asked.append("frame")
        return frameAnswer
    }
}

/// Geometry from real apps. Where a fixture was measured, it says where; where it was not, it
/// says what it is shaped after, and the "caret geometry:" lines of the diagnostic log are how to
/// replace it with a recording.
enum CaretGeometryFixtures {

    // MARK: Measured on Chrome, secondary display at x 2560 (#143)
    //
    // The rects are as measured. The caret offsets were not recorded, so those are illustrative.

    /// The address bar. The caret, and the character before it, come back as an empty rect at the
    /// bottom edge of the primary display.
    static func chromeOmnibox() -> RecordedTextElement {
        RecordedTextElement("Chrome address bar",
                            selection: CFRange(location: 11, length: 0),
                            bounds: ["11+0": CGRect(x: 0, y: 1440, width: 0, height: 0),
                                     "10+1": CGRect(x: 0, y: 1440, width: 0, height: 0)],
                            frame: CGRect(x: 4024, y: 77, width: 1203, height: 24))
    }

    /// An `<input>` on a page: empty rects at the top-left of the web content.
    static func chromeInput() -> RecordedTextElement {
        RecordedTextElement("Chrome <input>",
                            selection: CFRange(location: 5, length: 0),
                            bounds: ["5+0": CGRect(x: 3853, y: 147, width: 0, height: 0),
                                     "4+1": CGRect(x: 3853, y: 147, width: 0, height: 0)],
                            frame: CGRect(x: 4061, y: 355, width: 408, height: 22))
    }

    /// A `<textarea>`: same empty rects as the input.
    static func chromeTextarea() -> RecordedTextElement {
        RecordedTextElement("Chrome <textarea>",
                            selection: CFRange(location: 40, length: 0),
                            bounds: ["40+0": CGRect(x: 3853, y: 147, width: 0, height: 0),
                                     "39+1": CGRect(x: 3853, y: 147, width: 0, height: 0)],
                            frame: CGRect(x: 4061, y: 395, width: 504, height: 99))
    }

    /// A `contenteditable` div: empty rects at the bottom edge of the primary display.
    static func chromeContentEditable() -> RecordedTextElement {
        RecordedTextElement("Chrome contenteditable",
                            selection: CFRange(location: 20, length: 0),
                            bounds: ["20+0": CGRect(x: 0, y: 1440, width: 0, height: 0),
                                     "19+1": CGRect(x: 0, y: 1440, width: 0, height: 0)],
                            frame: CGRect(x: 4061, y: 517, width: 402, height: 82))
    }

    // MARK: Measured on TextEdit (#144)

    /// A real caret, 14 pt above the text view's own frame.
    static func textEdit() -> RecordedTextElement {
        RecordedTextElement("TextEdit",
                            selection: CFRange(location: 3, length: 0),
                            bounds: ["3+0": CGRect(x: 2966.35, y: 88, width: 0, height: 14)],
                            frame: CGRect(x: 2936, y: 102, width: 586, height: 382))
    }

    // MARK: Measured on the owner's Mac, Dia, 2026-11-07 and 08

    /// Dia, a Chromium browser, on a page whose editable area fills the window: an empty caret
    /// at the bottom edge of the 1117 pt primary display, at offset 0, and the window's content
    /// as the field.
    static func diaWindowSizedField() -> RecordedTextElement {
        RecordedTextElement("Dia, window-sized editable area",
                            selection: CFRange(location: 0, length: 0),
                            bounds: ["0+0": CGRect(x: 0, y: 1117, width: 0, height: 0)],
                            frame: CGRect(x: 190, y: 81, width: 1532, height: 1030))
    }

    /// Dia with the typing in a page: the same empty caret, and a field of an input's size
    /// reported 176 pt above the top of the screen.
    static func diaOffscreenField() -> RecordedTextElement {
        RecordedTextElement("Dia, field above the screen",
                            selection: CFRange(location: 0, length: 0),
                            bounds: ["0+0": CGRect(x: 0, y: 1117, width: 0, height: 0)],
                            frame: CGRect(x: 210, y: -176, width: 331, height: 22))
    }

    // MARK: Not measured: shaped after what is known of the app

    /// Terminal.app, shaped after the owner's check on #155: an empty caret at a position with no
    /// relation to the prompt, and the character before it placed on the prompt line. The text
    /// area is the whole window and the caret offset counts the scrollback. Provisional until
    /// replaced with a recording: coordinates and offsets are illustrative, only their shape
    /// matters to the decision.
    static func terminal() -> RecordedTextElement {
        RecordedTextElement("Terminal.app",
                            selection: CFRange(location: 5231, length: 0),
                            bounds: ["5231+0": CGRect(x: 0, y: 1440, width: 0, height: 0),
                                     "5230+1": CGRect(x: 247, y: 523, width: 7, height: 15)],
                            frame: CGRect(x: 120, y: 200, width: 732, height: 456))
    }

    /// Ghostty, read from its source (`SurfaceView_AppKit.swift`): the surface is an `AXTextArea`
    /// whose selected range is {0, 0} whenever nothing is selected, and it does not implement
    /// `accessibilityFrame(for:)`, so no range has bounds. The frame is one split's surface.
    static func ghostty() -> RecordedTextElement {
        RecordedTextElement("Ghostty",
                            selection: CFRange(location: 0, length: 0),
                            bounds: [:],
                            frame: CGRect(x: 0, y: 66, width: 1512, height: 916))
    }
}
