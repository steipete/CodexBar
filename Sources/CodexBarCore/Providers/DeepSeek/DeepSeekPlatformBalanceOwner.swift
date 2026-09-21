import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Live proof of the browser session that supplied a balance. Never persisted with usage snapshots.
public struct DeepSeekPlatformBalanceOwner: Sendable, Equatable {
    public let profileID: String
    public let tokenDigest: String

    public init?(profileID: String, token: String) {
        let profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileID.isEmpty, !token.isEmpty else { return nil }
        #if canImport(CryptoKit)
        self.profileID = profileID
        let material = "com.steipete.codexbar.deepseek-platform-balance.v1\0" + token
        self.tokenDigest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

public struct DeepSeekPlatformTransportError: LocalizedError, Sendable {
    public let owner: DeepSeekPlatformBalanceOwner?
    public let underlyingError: Error
    private let message: String

    init?(owner: DeepSeekPlatformBalanceOwner?, underlyingError: Error, description: String? = nil) {
        guard (underlyingError as NSError).domain == NSURLErrorDomain else { return nil }
        self.owner = owner
        self.underlyingError = underlyingError
        self.message = description ?? DeepSeekUsageError.networkError("Chrome session resolution unavailable")
            .localizedDescription
    }

    public var errorDescription: String? {
        self.message
    }
}
