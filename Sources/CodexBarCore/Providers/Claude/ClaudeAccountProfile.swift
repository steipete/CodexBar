import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Prompt-free Claude profile identity derived only from Claude-owned plain-text configuration.
public enum ClaudeAccountProfile {
    private struct ClaudeConfigAccount: Decodable {
        struct OAuthAccount: Decodable {
            let accountUuid: String?
        }

        let oauthAccount: OAuthAccount?
    }

    public static func accountUuid(environment: [String: String]) -> String? {
        let url = ClaudeConfigPaths.accountConfigURL(environment: environment)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ClaudeConfigAccount.self, from: data),
              let uuid = decoded.oauthAccount?.accountUuid?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uuid.isEmpty
        else {
            return nil
        }
        return uuid
    }

    /// A process-local ownership key for Claude TUI reuse. Missing identity fails closed with a fresh scope.
    public static func sessionScope(
        environment: [String: String],
        fallbackID: UUID = UUID()) -> String
    {
        let accountConfigPath = ClaudeConfigPaths.accountConfigURL(environment: environment).path
        let credentialsPath = ClaudeConfigPaths.credentialsURL(environment: environment).path
        let identity = self.accountUuid(environment: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let material = if let identity, !identity.isEmpty {
            "claude:cli-session:v2:\(accountConfigPath):\(credentialsPath):\(identity)"
        } else {
            "claude:cli-session-ephemeral:v2:\(accountConfigPath):\(credentialsPath):" +
                fallbackID.uuidString.lowercased()
        }
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
