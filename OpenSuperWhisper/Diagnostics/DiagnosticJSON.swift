import Foundation

/// Prepares MetricKit's diagnostic JSON for sending.
enum DiagnosticJSON {
    /// Where MetricKit records the locale, in its metadata. A report promises the app's stop point,
    /// its version and the macOS version, so this one never leaves the Mac.
    private static let localeKey = "regionFormat"

    /// The JSON with `regionFormat` removed wherever it appears, or nil when `data` is not JSON:
    /// the payload is an external input, and unread bytes are not worth the risk of a locale in them.
    static func withoutLocale(_ data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return try? JSONSerialization.data(withJSONObject: strip(json), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func strip(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.filter { $0.key != localeKey }.mapValues(strip)
        case let array as [Any]:
            return array.map(strip)
        default:
            return value
        }
    }
}
