import Foundation

#if os(macOS)
@_implementationOnly import autocorrect
#endif

/// Swift wrapper for the autocorrect C library.
/// macOS: real impl over the vendored Rust dylib (via the `autocorrect` clang module).
/// iOS: no-op — the dylib is macOS-only in Cycle 1 (plan KD #5).
public class AutocorrectWrapper {

    /// Format text using autocorrect
    /// - Parameter text: The text to format
    /// - Returns: The formatted text, or original text if autocorrect fails
    public static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }

#if os(macOS)
        guard let cText = text.cString(using: .utf8) else {
            print("Failed to convert text to C string")
            return text
        }

        guard let formattedCString = autocorrect_format(cText) else {
            print("Autocorrect format returned null")
            return text
        }

        defer {
            autocorrect_free_string(formattedCString)
        }

        guard let formattedText = String(cString: formattedCString, encoding: .utf8) else {
            print("Failed to convert formatted C string back to Swift string")
            return text
        }

        return formattedText
#else
        return text
#endif
    }

    /// Format text for a specific file type
    /// - Parameters:
    ///   - text: The text to format
    ///   - filename: The filename to determine formatting rules
    /// - Returns: The formatted text, or original text if autocorrect fails
    public static func format(_ text: String, for filename: String) -> String {
        guard !text.isEmpty else { return text }

#if os(macOS)
        guard let cText = text.cString(using: .utf8),
              let cFilename = filename.cString(using: .utf8) else {
            print("Failed to convert text or filename to C string")
            return text
        }

        guard let formattedCString = autocorrect_format_for(cText, cFilename) else {
            print("Autocorrect format_for returned null")
            return text
        }

        defer {
            autocorrect_free_string(formattedCString)
        }

        guard let formattedText = String(cString: formattedCString, encoding: .utf8) else {
            print("Failed to convert formatted C string back to Swift string")
            return text
        }

        return formattedText
#else
        return text
#endif
    }

    /// Check if autocorrect library is available
    /// - Returns: true if the library can be used, false otherwise
    public static func isAvailable() -> Bool {
#if os(macOS)
        // Test by trying to format an empty string
        let testResult = autocorrect_format("")
        if testResult != nil {
            autocorrect_free_string(testResult)
            return true
        }
        return false
#else
        return false
#endif
    }
}
