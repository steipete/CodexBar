import Foundation

/// Describes WHERE a Claude token account's live credential comes from.
///
/// A `ProviderTokenAccount.token` for Claude is either a raw OAuth/session
/// token (legacy / manually pasted — classified directly by
/// `ClaudeCredentialRouting`) or an encoded *source pointer* that the fetch
/// path resolves — and refreshes — at fetch time. The pointer lets several
/// Claude accounts each read and refresh from their own Keychain item or
/// `~/.claude*` config dir, instead of all sharing the single default login.
public enum ClaudeCredentialSource: Sendable, Equatable, Codable {
    /// A literal credential value stored directly (no per-account refresh).
    case oauthToken(String)
    /// A macOS Keychain generic-password item (service + optional account).
    case keychainService(service: String, account: String?)
    /// A Claude credentials JSON file (e.g. `~/.claude-acct2/.credentials.json`).
    case credentialsFile(path: String)
    /// An environment variable holding the token.
    case environment(key: String)

    /// Marker prefix for encoded source pointers stored in a token-account token.
    public static let descriptorPrefix = "claude-source:"

    /// Environment variable that carries a source descriptor from the
    /// token-account override into the Claude fetcher, where it is resolved and
    /// refreshed per account at fetch time.
    public static let environmentDescriptorKey = "CODEXBAR_CLAUDE_SOURCE"

    /// True for sources that point at a refreshable store (vs a static token).
    public var isRefreshableSource: Bool {
        switch self {
        case .oauthToken:
            return false
        case .keychainService, .credentialsFile, .environment:
            return true
        }
    }

    /// Encode for storage in a `ProviderTokenAccount.token`. A raw token stays
    /// raw (back-compat: routing classifies it directly); pointers are encoded
    /// as `claude-source:<base64 JSON>` so any service / path / email — even
    /// with `:`, spaces, or `=` — round-trips intact.
    public func encodedTokenValue() -> String {
        if case let .oauthToken(token) = self {
            return token
        }
        guard let data = try? JSONEncoder().encode(self), !data.isEmpty else {
            return ""
        }
        return Self.descriptorPrefix + data.base64EncodedString()
    }

    /// Inverse of `encodedTokenValue()`. Anything without the marker prefix (or
    /// that fails to decode) is treated as a legacy raw token.
    public static func parse(_ tokenValue: String) -> ClaudeCredentialSource {
        let trimmed = tokenValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.descriptorPrefix) else {
            return .oauthToken(tokenValue)
        }
        let encoded = String(trimmed.dropFirst(Self.descriptorPrefix.count))
        guard let data = Data(base64Encoded: encoded),
              let decoded = try? JSONDecoder().decode(ClaudeCredentialSource.self, from: data)
        else {
            return .oauthToken(tokenValue)
        }
        return decoded
    }

    /// Short human label for menus / settings rows.
    public func displayLabel() -> String {
        switch self {
        case .oauthToken:
            return "Pasted token"
        case let .keychainService(service, account):
            if let account, !account.isEmpty {
                return account
            }
            return service
        case let .credentialsFile(path):
            let parent = (path as NSString).deletingLastPathComponent
            let name = (parent as NSString).lastPathComponent
            return name.isEmpty ? path : name
        case let .environment(key):
            return key
        }
    }
}
