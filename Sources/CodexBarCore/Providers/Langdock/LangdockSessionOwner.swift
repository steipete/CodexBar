import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Live-only proof of the selected browser session. Never encoded with usage or written to logs.
public struct LangdockSessionOwner: Sendable, Equatable {
    public let profileID: String
    let tokenDigest: String

    init?(profileID: String, cookieHeader: String) {
        let tokens = Set(CookieHeaderNormalizer.pairs(from: cookieHeader)
            .filter { $0.name == "auth_token" }.map(\.value))
        guard !profileID.isEmpty, tokens.count == 1, let token = tokens.first, !token.isEmpty else { return nil }
        #if canImport(CryptoKit)
        self.profileID = profileID
        let material = "com.steipete.codexbar.langdock-session.v1\0" + token
        self.tokenDigest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

/// Carries freshly revalidated ownership even when the usage request fails.
public struct LangdockFetchError: LocalizedError, Sendable {
    public let owner: LangdockSessionOwner?
    public let underlyingError: Error

    public var errorDescription: String? {
        self.underlyingError.localizedDescription
    }
}

extension UsageSnapshot {
    func withLangdockSessionOwner(_ owner: LangdockSessionOwner) -> UsageSnapshot {
        self.replacing(langdockSessionOwner: .value(owner))
    }
}
