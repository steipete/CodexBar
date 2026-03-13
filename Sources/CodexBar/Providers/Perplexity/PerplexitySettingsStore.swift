import CodexBarCore
import Foundation
import Security

// MARK: - SettingsStore + Perplexity

extension SettingsStore {
    private static let perplexityKeychainService = "com.codexbarrt.perplexity"
    private static let perplexityKeychainAccount = "session-cookie"

    /// The Perplexity session cookie stored in Keychain.
    /// Reads from and writes to the same Keychain item the fetch strategy uses.
    var perplexitySessionCookie: String {
        get {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.perplexityKeychainService,
                kSecAttrAccount: Self.perplexityKeychainAccount,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty
            else { return "" }
            return value
        }
        set {
            let normalized = self.normalizedConfigValue(newValue) ?? ""

            let deleteQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.perplexityKeychainService,
                kSecAttrAccount: Self.perplexityKeychainAccount,
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            if !normalized.isEmpty {
                let addQuery: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: Self.perplexityKeychainService,
                    kSecAttrAccount: Self.perplexityKeychainAccount,
                    kSecValueData: Data(normalized.utf8),
                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
                ]
                SecItemAdd(addQuery as CFDictionary, nil)
            }

            self.logSecretUpdate(provider: .perplexity, field: "sessionCookie", value: newValue)
        }
    }

    func ensurePerplexitySessionCookieLoaded() {}
}
