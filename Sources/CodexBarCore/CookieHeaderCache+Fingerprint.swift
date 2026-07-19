import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

extension CookieHeaderCache {
    /// Stable, non-reversible identifier for a normalized credential. Safe for cache-scope
    /// comparisons; never expose the cookie header itself to UI, logs, or persisted reports.
    public static func credentialFingerprint(_ cookieHeader: String) -> String {
        let normalized = CookieHeaderNormalizer.normalize(cookieHeader) ?? cookieHeader
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #else
        let digest = normalized.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(digest, radix: 16)
        #endif
    }
}
