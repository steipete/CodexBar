#if os(macOS)
import CryptoKit
import Foundation
import WebKit

/// Per-account persistent `WKWebsiteDataStore` for the OpenAI dashboard scrape.
///
/// Why: `WKWebsiteDataStore.default()` is a single shared cookie jar. If the user switches Codex accounts,
/// we want to keep multiple signed-in dashboard sessions around (one per email/workspace pair) without clearing
/// cookies.
///
/// Implementation detail: macOS 14+ supports `WKWebsiteDataStore.dataStore(forIdentifier:)`, which creates
/// persistent isolated stores keyed by an identifier. We derive a stable UUID from the normalized email/workspace key
/// so the same account workspace always maps to the same cookie store.
///
/// Important: We cache the `WKWebsiteDataStore` instances so the same object is returned for the same
/// account key. This ensures `OpenAIDashboardWebViewCache` can use object identity for cache lookups.
@MainActor
public enum OpenAIDashboardWebsiteDataStore {
    /// Cached data store instances keyed by normalized account identity.
    /// Using the same instance ensures stable object identity for WebView cache lookups.
    private static var cachedStores: [String: WKWebsiteDataStore] = [:]

    public static func store(forAccountEmail email: String?, workspaceLabel: String? = nil) -> WKWebsiteDataStore {
        guard let normalized = normalizeAccountKey(email: email, workspaceLabel: workspaceLabel)
        else { return .default() }

        if let cached = cachedStores[normalized] {
            return cached
        }

        let id = Self.identifier(forNormalizedKey: normalized)
        let store = WKWebsiteDataStore(forIdentifier: id)
        self.cachedStores[normalized] = store
        return store
    }

    /// Clears the persistent cookie store for a single account identity.
    ///
    /// Note: this does *not* impact other accounts, and is safe to use when the stored session is "stuck"
    /// or signed in to a different account than expected.
    public static func clearStore(forAccountEmail email: String?, workspaceLabel: String? = nil) async {
        let store = self.store(forAccountEmail: email, workspaceLabel: workspaceLabel)
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

        if let normalized = normalizeAccountKey(email: email, workspaceLabel: workspaceLabel) {
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

    private static func normalizeAccountKey(email: String?, workspaceLabel: String?) -> String? {
        guard let rawEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines), !rawEmail.isEmpty else {
            return nil
        }
        let normalizedEmail = rawEmail.lowercased()
        let normalizedWorkspace = workspaceLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedWorkspace, !normalizedWorkspace.isEmpty {
            return "\(normalizedEmail)\n\(normalizedWorkspace)"
        }
        return normalizedEmail
    }

    private static func identifier(forNormalizedKey key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
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
