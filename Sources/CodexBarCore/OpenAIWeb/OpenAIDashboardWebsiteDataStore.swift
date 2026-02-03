#if os(macOS)
import CryptoKit
import Foundation
import WebKit

/// Per-account persistent `WKWebsiteDataStore` for the OpenAI dashboard scrape.
///
/// Why: `WKWebsiteDataStore.default()` is a single shared cookie jar. If the user switches Codex accounts,
/// we want to keep multiple signed-in dashboard sessions around (one per email) without clearing cookies.
///
/// Implementation detail: macOS 14+ supports `WKWebsiteDataStore.dataStore(forIdentifier:)`, which creates
/// persistent isolated stores keyed by an identifier. We derive a stable UUID from the email so the same
/// account always maps to the same cookie store.
///
/// Important: We cache the `WKWebsiteDataStore` instances so the same object is returned for the same
/// account email. This ensures `OpenAIDashboardWebViewCache` can use object identity for cache lookups.
@MainActor
public enum OpenAIDashboardWebsiteDataStore {
    /// Cached data store instances keyed by normalized email.
    /// Using the same instance ensures stable object identity for WebView cache lookups.
    private static var cachedStores: [String: WKWebsiteDataStore] = [:]

    public static func store(forAccountEmail email: String?) -> WKWebsiteDataStore {
        guard let normalized = normalizeEmail(email) else { return .default() }

        // Return cached instance if available to maintain stable object identity
        if let cached = cachedStores[normalized] {
            return cached
        }

        let id = Self.identifier(forNormalizedEmail: normalized)
        let store = WKWebsiteDataStore(forIdentifier: id)
        self.cachedStores[normalized] = store
        return store
    }

    /// Clears the persistent cookie store for a single account email.
    ///
    /// Note: this does *not* impact other accounts, and is safe to use when the stored session is "stuck"
    /// or signed in to a different account than expected.
    public static func clearStore(forAccountEmail email: String?) async {
        // Clear only ChatGPT/OpenAI domain data for the per-account store.
        // Avoid deleting the entire persistent store (WebKit requires all WKWebViews using it to be released).
        let store = self.store(forAccountEmail: email)
        await withCheckedContinuation { cont in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let filtered = records.filter { record in
                    let name = record.displayName.lowercased()
                    return name.contains("chatgpt.com") || name.contains("openai.com")
                }
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: filtered) {
                    cont.resume()
                }
            }
        }

        // Remove from cache so a fresh instance is created on next access
        if let normalized = normalizeEmail(email) {
            self.cachedStores.removeValue(forKey: normalized)
        }
    }

    #if DEBUG
    /// Clear all cached store instances (for test isolation).
    public static func clearCacheForTesting() {
        self.cachedStores.removeAll()
    }
    #endif

    // MARK: - Private

    private static func normalizeEmail(_ email: String?) -> String? {
        guard let raw = email?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    private static func identifier(forNormalizedEmail email: String) -> UUID {
        let digest = SHA256.hash(data: Data(email.utf8))
        var bytes = Array(digest.prefix(16))

        // Make it a well-formed UUID (v4 + RFC4122 variant) while staying deterministic.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let uuidBytes: uuid_t = (
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15])
        return UUID(uuid: uuidBytes)
    }
}
#endif
