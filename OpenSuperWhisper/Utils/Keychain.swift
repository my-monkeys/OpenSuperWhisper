import Foundation
import Security

/// Minimal Keychain wrapper for small secrets (e.g. the Groq API key). Stored as generic passwords
/// under the app's bundle id so they don't sit in plain-text UserDefaults.
enum Keychain {
    /// Under XCTest, a service of its own, for the same reason `DefaultsStore` swaps its suite.
    /// The test host is not the binary that created the user's items, so reading one raised a
    /// Keychain prompt that nobody was there to answer and the test hung; and a write, which
    /// deletes before it adds, would have replaced the user's real API key.
    private static let service = DefaultsStore.isRunningTests
        ? "\(AppIdentity.bundleID).tests"
        : "fr.my-monkey.opensuperwhisper"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
