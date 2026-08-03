import Foundation

/// One thing the recording bubble can show. The bubble draws exactly the elements in
/// `IndicatorLayout.elements`, in that order, which is what makes the layout editor possible:
/// composition replaces the pile of independent booleans that used to decide the contents
/// (show stop, show cancel, where the meter goes) and could combine into layouts nobody had
/// ever looked at.
enum IndicatorElement: String, Codable, CaseIterable, Identifiable {
    case dot
    case waveform
    case label
    case stopButton
    case cancelButton

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dot: return "Blinking dot"
        case .waveform: return "Waveform"
        case .label: return "\"Recording…\" label"
        case .stopButton: return "Stop button"
        case .cancelButton: return "Cancel button"
        }
    }

    var subtitle: String {
        switch self {
        case .dot: return "The classic red dot"
        case .waveform: return "Live spectrum of the mic input"
        case .label: return "Also shows how many clips are queued"
        case .stopButton: return "Stops and transcribes"
        case .cancelButton: return "Discards the recording"
        }
    }

    var symbol: String {
        switch self {
        case .dot: return "record.circle"
        case .waveform: return "waveform"
        case .label: return "textformat"
        case .stopButton: return "stop.circle"
        case .cancelButton: return "trash"
        }
    }

    /// Buttons sit at the trailing edge, after a spacer, however the list is ordered. Letting
    /// them float mid-row would put a click target between the meter and the text.
    var isTrailingControl: Bool {
        self == .stopButton || self == .cancelButton
    }
}

/// The bubble's contents and geometry.
///
/// `order` holds every element, shown or not, so an element keeps its position while switched
/// off and lands there when switched back on instead of jumping to the end. `hidden` is the
/// subtracted set rather than a list of shown elements, so a future element appears by default
/// rather than silently missing from everyone's stored layout.
struct IndicatorLayout: Codable, Equatable {
    var order: [IndicatorElement]
    var hidden: Set<IndicatorElement>
    /// Height of the waveform bars. Also the tallest element, so it drives the bubble's height.
    var waveformHeight: Double

    static let defaultWaveformHeight: Double = 30

    static let `default` = IndicatorLayout(
        order: [.dot, .waveform, .label, .stopButton, .cancelButton],
        hidden: [.dot, .stopButton, .cancelButton],
        waveformHeight: defaultWaveformHeight)

    func isVisible(_ element: IndicatorElement) -> Bool { !hidden.contains(element) }

    /// Shown elements, in order.
    var elements: [IndicatorElement] { order.filter(isVisible) }

    func contains(_ element: IndicatorElement) -> Bool { elements.contains(element) }

    /// Leading elements in their configured order, then the trailing controls, so a button
    /// moved to the front still renders at the edge where a click target belongs.
    var leading: [IndicatorElement] { elements.filter { !$0.isTrailingControl } }
    var trailing: [IndicatorElement] { elements.filter(\.isTrailingControl) }

    mutating func setVisible(_ visible: Bool, for element: IndicatorElement) {
        if visible { hidden.remove(element) } else { hidden.insert(element) }
    }

    /// Moves `dragged` to sit where `target` currently is.
    mutating func move(_ dragged: IndicatorElement, before target: IndicatorElement) {
        guard dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target)
        else { return }
        order.remove(at: from)
        order.insert(dragged, at: to)
    }

    // MARK: - Persistence

    static func load(from json: String) -> IndicatorLayout {
        guard let data = json.data(using: .utf8),
              var decoded = try? JSONDecoder().decode(IndicatorLayout.self, from: data)
        else { return .default }
        // Repair a stored order that lost or repeated entries (older build, hand-edited
        // defaults): every element must appear exactly once for the editor to list it.
        var seen = Set<IndicatorElement>()
        decoded.order = decoded.order.filter { seen.insert($0).inserted }
        decoded.order += IndicatorElement.allCases.filter { !seen.contains($0) }
        return decoded
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    /// Builds the layout a pre-editor install should start from, so nobody's bubble changes
    /// shape on upgrade. `meterMode` is the old "off" / "replacesDot" / "besideLabel" value.
    static func migrated(meterMode: String, showStop: Bool, showCancel: Bool) -> IndicatorLayout {
        var layout = IndicatorLayout.default
        switch meterMode {
        case "off":
            layout.order = [.dot, .label, .waveform, .stopButton, .cancelButton]
            layout.hidden = [.waveform]
        case "besideLabel":
            layout.order = [.dot, .label, .waveform, .stopButton, .cancelButton]
            layout.hidden = []
        default:
            layout.order = [.waveform, .label, .dot, .stopButton, .cancelButton]
            layout.hidden = [.dot]
        }
        if !showStop { layout.hidden.insert(.stopButton) }
        if !showCancel { layout.hidden.insert(.cancelButton) }
        return layout
    }
}
