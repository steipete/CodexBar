import Foundation

/// The Grok CLI remains the only refresh-token consumer and auth.json writer.
/// CodexBar accepts its result only after reloading the same account from disk.
enum GrokSessionRecovery {
    typealias Renew = @Sendable ([String: String]) async throws -> String?

    static func recover(
        _ original: GrokCredentials,
        environment: [String: String],
        renew: Renew = renewUsingCLI) async throws -> GrokCredentials
    {
        guard original.isExpired else { return original }
        guard original.authMode == "oidc",
              original.oidcIssuer == "https://auth.x.ai",
              let clientID = original.oidcClientId,
              original.scope == GrokCredentialsStore.oidcScopePrefix + clientID,
              let refreshToken = original.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              environment["GROK_AUTH"] == nil,
              environment["GROK_AUTH_PATH"] == nil,
              environment["GROK_AUTH_PROVIDER_COMMAND"] == nil
        else {
            throw GrokWebBillingError.missingCredentials
        }
        try Task.checkCancellation()
        let before = try GrokCredentialsStore.load(env: environment)
        guard self.sameAccount(original, before),
              before.accessToken == original.accessToken,
              before.refreshToken == original.refreshToken
        else {
            throw GrokWebBillingError.missingCredentials
        }

        let token = try await renew(environment)
        try Task.checkCancellation()
        // Never persist or recreate a deleted auth file. A login/logout during the
        // request invalidates this fetch, even if the CLI returned a usable token.
        let current = try GrokCredentialsStore.load(env: environment)
        guard let token, !token.isEmpty,
              current.accessToken == token,
              !current.isExpired,
              self.sameAccount(original, current)
        else {
            throw GrokWebBillingError.missingCredentials
        }
        return current
    }

    private static func sameAccount(_ lhs: GrokCredentials, _ rhs: GrokCredentials) -> Bool {
        lhs.scope == rhs.scope && lhs.userId == rhs.userId && lhs.email == rhs.email
            && lhs.teamId == rhs.teamId && lhs.principalType == rhs.principalType
            && lhs.oidcIssuer == rhs.oidcIssuer && lhs.oidcClientId == rhs.oidcClientId
    }

    private static func renewUsingCLI(environment: [String: String]) async throws -> String? {
        // Use the CLI's shared owner rather than killing a refresh-owning process
        // when this client's request times out.
        let client = try GrokRPCClient(
            arguments: ["agent", "--leader", "stdio"],
            environment: environment,
            initializeTimeoutSeconds: 8,
            requestTimeoutSeconds: 12)
        defer { client.shutdown() }
        try await client.initialize()
        return try await client.fetchValidBearerToken()
    }
}
