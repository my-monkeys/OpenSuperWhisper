import Foundation
import Security

/// Minimal Keychain wrapper for small secrets (e.g. the Groq API key). Stored as generic passwords
/// under the app's bundle id so they don't sit in plain-text UserDefaults.
public enum Keychain {
    /// Under XCTest, a service of its own, for the same reason `DefaultsStore` swaps its suite.
    /// The test host is not the binary that created the user's items, so reading one raised a
    /// Keychain prompt that nobody was there to answer and the test hung; and a write, which
    /// deletes before it adds, would have replaced the user's real API key.
    static let service = DefaultsStore.isRunningTests
        ? "\(AppIdentity.bundleID).tests"
        : productionService

    /// The service every shipped build stores its items under. Named on its own so a test can
    /// pin it while `service` points elsewhere: a different spelling would lose every saved key.
    static let productionService = "fr.my-monkey.opensuperwhisper"

    public static func read(_ account: String) -> String? {
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

    public static func set(_ value: String?, for account: String) {
        SecItemDelete(itemQuery(for: account) as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        SecItemAdd(addQuery(for: account, data: data) as CFDictionary, nil)
    }

    /// What `set` deletes by. Internal so a test can pin it.
    static func itemQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// What `set` adds. Internal so a test can pin the accessibility, which the legacy file
    /// keychain the test host writes to does not report back on a read.
    static func addQuery(for account: String, data: Data) -> [String: Any] {
        var add = itemQuery(for: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return add
    }
}
