import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Process-lifetime, in-memory cache of freshly-minted ZoomMate bearer JWTs.
///
/// The `.auto` cookie-mint path exchanges long-lived browser session cookies for a short-lived
/// (~hourly) bearer JWT on demand. Without a cache that mint happens on *every* refresh; this cache
/// lets a still-valid token be reused across refreshes instead.
///
/// Safety properties (why reuse can't serve a bad token):
///   - Entries are keyed by a non-reversible SHA-256 of the originating cookie header, so distinct
///     browser sessions / accounts never collide and the raw cookies are never stored as a key.
///   - A token is cached *only* when its JWT carries a decodable `exp` claim, and is served only
///     while `now < exp - refreshSkew`. A token whose expiry cannot be determined is never cached
///     (the caller mints fresh), so the cache can never hand back a token past its own expiry.
///   - Nothing is persisted — the cache is empty on every launch.
///
/// A revoked-before-expiry session is handled by the caller: a `401/403` from a downstream request
/// evicts the entry (see `ZoomMateWebFetchStrategy`) so the next refresh mints fresh.
actor ZoomMateBearerTokenCache {
    static let shared = ZoomMateBearerTokenCache()

    /// Refresh this many seconds before the JWT's own `exp`, so an in-flight request never rides a
    /// token that expires mid-flight.
    static let refreshSkew: TimeInterval = 60

    struct Entry: Sendable {
        let token: String
        let accountEmail: String?
        let expiry: Date
    }

    private var entries: [String: Entry] = [:]

    /// Non-reversible cache key for a cookie session. SHA-256 hex of the raw cookie header.
    static func key(forCookieHeader cookieHeader: String) -> String {
        let digest = SHA256.hash(data: Data(cookieHeader.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the cached entry for `key` when it is still comfortably in-date, evicting and
    /// returning `nil` once it enters the `refreshSkew` window (or has passed `exp`).
    func validEntry(forKey key: String, now: Date) -> Entry? {
        guard let entry = self.entries[key] else { return nil }
        guard entry.expiry.addingTimeInterval(-Self.refreshSkew) > now else {
            self.entries[key] = nil
            return nil
        }
        return entry
    }

    func store(_ entry: Entry, forKey key: String) {
        self.entries[key] = entry
    }

    func invalidate(forKey key: String) {
        self.entries[key] = nil
    }
}
