import Foundation
#if os(macOS)
import Security
#endif

/// Resolves a `ClaudeCredentialSource` into a live OAuth access token at fetch
/// time, refreshing if the stored token has expired. This is what lets several
/// Claude accounts each refresh from their own Keychain item / config dir,
/// instead of all sharing the single default login.
///
/// Write-back policy (important): when a refresh rotates the refresh token, the
/// new credential is persisted back to its source ONLY for **secondary** sources
/// (a non-default Keychain service or a credentials file — i.e. CLAUDE_CONFIG_DIR
/// accounts that Claude Code does not actively refresh). The default
/// `"Claude Code-credentials"` item is left untouched so we never race Claude
/// Code's own refresh of it (which is how token families get revoked).
public enum ClaudeCredentialResolver {
    /// Convenience: the access token from `resolveCredentials`.
    public static func resolveAccessToken(
        from source: ClaudeCredentialSource,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> String
    {
        try await self.resolveCredentials(from: source, environment: environment).accessToken
    }

    /// Read the credential for `source` and refresh if expired, returning live
    /// credentials (scopes preserved, so downstream scope checks still pass).
    public static func resolveCredentials(
        from source: ClaudeCredentialSource,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ClaudeOAuthCredentials
    {
        switch source {
        case let .oauthToken(token):
            return self.staticCredentials(token)
        case let .environment(key):
            let token = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else { throw ClaudeOAuthCredentialsError.notFound }
            return self.staticCredentials(token)
        case let .credentialsFile(path):
            return try await self.refreshed(self.readCredentialsFile(path: path), persistTo: source)
        case let .keychainService(service, account):
            return try await self.refreshed(
                self.readKeychain(service: service, account: account), persistTo: source)
        }
    }

    private static func staticCredentials(_ token: String) -> ClaudeOAuthCredentials {
        ClaudeOAuthCredentials(
            accessToken: token, refreshToken: nil, expiresAt: nil,
            scopes: [], rateLimitTier: nil)
    }

    /// Best-effort account email for an access token, via the OAuth profile
    /// endpoint. Used to label and de-duplicate discovered accounts. Returns nil
    /// on any failure (network, scope, parse) — callers fall back gracefully.
    public static func fetchAccountEmail(accessToken: String) async -> String? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            if let account = obj["account"] as? [String: Any],
               let email = account["email"] as? String, !email.isEmpty
            {
                return email
            }
            if let email = obj["email"] as? String, !email.isEmpty { return email }
            return nil
        } catch {
            return nil
        }
    }

    static func refreshed(
        _ creds: ClaudeOAuthCredentials,
        persistTo source: ClaudeCredentialSource) async throws -> ClaudeOAuthCredentials
    {
        // Not expired, or nothing to refresh with — use as-is. (A stale token
        // with no refresh token surfaces a clear auth error → reconnect.)
        guard creds.isExpired, let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            return creds
        }
        let refreshed = try await ClaudeOAuthCredentialsStore.refreshAccessToken(
            refreshToken: refreshToken,
            existingScopes: creds.scopes,
            existingRateLimitTier: creds.rateLimitTier,
            existingSubscriptionType: creds.subscriptionType)
        if self.shouldPersist(to: source) {
            try? self.persist(refreshed, to: source)
        }
        return refreshed
    }

    /// Only write rotated credentials back to secondary sources (see type doc).
    static func shouldPersist(to source: ClaudeCredentialSource) -> Bool {
        switch source {
        case .credentialsFile:
            return true
        case let .keychainService(service, _):
            return service != ClaudeAccountDiscovery.defaultKeychainService
        case .oauthToken, .environment:
            return false
        }
    }

    // MARK: - reading

    static func readCredentialsFile(path: String) throws -> ClaudeOAuthCredentials {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        return try ClaudeOAuthCredentials.parse(data: data)
    }

    static func readKeychain(service: String, account: String?) throws -> ClaudeOAuthCredentials {
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account, !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        }
        return try ClaudeOAuthCredentials.parse(data: data)
        #else
        throw ClaudeOAuthCredentialsError.notFound
        #endif
    }

    // MARK: - write-back

    static func persist(_ creds: ClaudeOAuthCredentials, to source: ClaudeCredentialSource) throws {
        let json = try self.encodeCredentialsJSON(creds)
        switch source {
        case let .credentialsFile(path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try json.write(to: url, options: .atomic)
        case let .keychainService(service, account):
            #if os(macOS)
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            if let account, !account.isEmpty {
                query[kSecAttrAccount as String] = account
            }
            let attributes: [String: Any] = [kSecValueData as String: json]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw ClaudeOAuthCredentialsError.keychainError(Int(status))
            }
            #endif
        case .oauthToken, .environment:
            break
        }
    }

    /// Encode credentials in Claude Code's `{"claudeAiOauth": {…}}` shape so a
    /// write-back is readable by both CodexBar and Claude Code.
    static func encodeCredentialsJSON(_ creds: ClaudeOAuthCredentials) throws -> Data {
        var oauth: [String: Any] = ["accessToken": creds.accessToken]
        if let refreshToken = creds.refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt = creds.expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000.0)
        }
        if !creds.scopes.isEmpty { oauth["scopes"] = creds.scopes }
        if let tier = creds.rateLimitTier { oauth["rateLimitTier"] = tier }
        if let sub = creds.subscriptionType { oauth["subscriptionType"] = sub }
        return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }
}
