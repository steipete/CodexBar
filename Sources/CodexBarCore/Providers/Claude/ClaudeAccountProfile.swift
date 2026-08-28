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

    /// What Claude's plaintext account config can prove about CLI credential ownership.
    /// `signedOut` requires positive evidence (no config file, or a cleanly parsed config with no
    /// OAuth account); an unreadable, malformed, or unrecognized config is `indeterminate` because
    /// it cannot establish that CLI storage is absent.
    public enum ConfigOwnershipEvidence: Equatable, Sendable {
        case signedIn(accountUuid: String)
        case signedOut
        case indeterminate
    }

    public static func accountUuid(environment: [String: String]) -> String? {
        guard case let .signedIn(uuid) = self.configOwnershipEvidence(environment: environment) else {
            return nil
        }
        return uuid
    }

    public static func configOwnershipEvidence(environment: [String: String]) -> ConfigOwnershipEvidence {
        let url = ClaudeConfigPaths.accountConfigURL(environment: environment)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
        {
            // A verifiably missing config is positive evidence that no signed-in CLI exists here.
            return .signedOut
        } catch {
            // Present but unreadable (permissions, I/O): cannot prove CLI storage is absent.
            return .indeterminate
        }
        guard let decoded = try? JSONDecoder().decode(ClaudeConfigAccount.self, from: data) else {
            // Malformed or unrecognized schema: cannot prove CLI storage is absent.
            return .indeterminate
        }
        guard let oauthAccount = decoded.oauthAccount else {
            return .signedOut
        }
        guard let uuid = oauthAccount.accountUuid?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uuid.isEmpty
        else {
            // An OAuth account stanza without a usable identity is not proof of a signed-out CLI.
            return .indeterminate
        }
        return .signedIn(accountUuid: uuid)
    }

    /// A process-local ownership key for Claude TUI reuse. Missing identity fails closed with a fresh scope.
    public static func sessionScope(
        environment: [String: String],
        fallbackID: UUID = UUID()) -> String
    {
        self.makeSessionScope(
            environment: environment,
            identity: self.accountUuid(environment: environment),
            fallbackID: fallbackID)
    }

    /// A stable ownership key only when Claude's selected profile exposes an account identity.
    /// Background work must fail closed rather than let an unidentified profile inherit another profile's marker.
    static func identifiedSessionScope(environment: [String: String]) -> String? {
        guard let identity = self.accountUuid(environment: environment) else { return nil }
        return self.makeSessionScope(environment: environment, identity: identity, fallbackID: UUID())
    }

    private static func makeSessionScope(
        environment: [String: String],
        identity: String?,
        fallbackID: UUID) -> String
    {
        let accountConfigPath = ClaudeConfigPaths.accountConfigURL(environment: environment).path
        let credentialsPath = ClaudeConfigPaths.credentialsURL(environment: environment).path
        let identity = identity?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
