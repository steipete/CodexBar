import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension ClaudeOAuthCredentialsStore {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sha256Prefix(_ data: Data) -> String? {
        String(self.sha256Hex(data).prefix(12))
    }
}
