import CodexBarCore
import Foundation

// MARK: - SettingsStore + Perplexity

extension SettingsStore {
    /// The Perplexity session cookie stored in Keychain.
    /// Reads from and writes to the same Keychain item the fetch strategy uses.
    var perplexitySessionCookie: String {
        get {
            PerplexityKeychainStore.readCookie() ?? ""
        }
        set {
            let normalized = self.normalizedConfigValue(newValue) ?? ""
            do {
                if normalized.isEmpty {
                    PerplexityKeychainStore.clearCookie()
                } else {
                    try PerplexityKeychainStore.writeCookie(normalized)
                }
            } catch {
                CodexBarLog.logger(LogCategories.settings).error(
                    "Failed to update Perplexity session cookie",
                    metadata: [
                        "provider": UsageProvider.perplexity.rawValue,
                        "error": error.localizedDescription,
                    ])
            }

            self.logSecretUpdate(provider: .perplexity, field: "sessionCookie", value: newValue)
        }
    }

    func ensurePerplexitySessionCookieLoaded() {}
}
