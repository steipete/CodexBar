import Foundation

public struct AntigravityAuthorizedFetchStrategy: ProviderFetchStrategy {
    public let id: String = "antigravity.authorized"
    public let kind: ProviderFetchKind = .oauth

    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard let accountLabel = context.settings?.antigravity?.accountLabel else {
            Self.log.debug("Authorized strategy not available: no account label")
            return false
        }

        Self.log.debug("Checking authorized strategy availability for account: \(accountLabel)")

        if let manualCredentials = self.loadManualCredentials(accountLabel: accountLabel, context: context) {
            Self.log.debug("Manual credentials found")
            return !manualCredentials.accessToken.isEmpty
        }

        guard let credentials = AntigravityOAuthCredentialsStore.load(accountLabel: accountLabel) else {
            Self.log.debug("Keychain credentials not found")
            return false
        }
        
        Self.log.debug("Keychain credentials found - hasAccessToken: \(!credentials.accessToken.isEmpty), isRefreshable: \(credentials.isRefreshable)")
        
        if !credentials.accessToken.isEmpty { return true }
        return credentials.isRefreshable
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        Self.log.debug("Fetching with authorized strategy")
        
        let resolved = try await self.resolveCredentials(context: context)
        let accountLabel = resolved.accountLabel
        let credentials = resolved.credentials
        let sourceLabel = resolved.sourceLabel

        Self.log.debug("Resolved credentials - source: \(sourceLabel), needsRefresh: \(credentials.needsRefresh), isRefreshable: \(credentials.isRefreshable)")

        var refreshedCredentials: AntigravityOAuthCredentials?
        if credentials.needsRefresh || (credentials.accessToken.isEmpty && credentials.isRefreshable) {
            Self.log.debug("Credentials need refresh, refreshing token...")
            let refreshed = try await self.refreshCredentials(credentials)
            refreshedCredentials = refreshed
            Self.log.debug("Token refresh successful")
            if KeychainAccessGate.isDisabled {
                context.onCredentialsRefreshed?(.antigravity, accountLabel, refreshed.accessToken)
            } else {
                _ = AntigravityOAuthCredentialsStore.save(refreshed, accountLabel: accountLabel)
            }
        }

        let activeCredentials = refreshedCredentials ?? credentials
        let quota = try await AntigravityCloudCodeClient.fetchQuota(accessToken: activeCredentials.accessToken)
        Self.log.debug("Successfully fetched quota from Cloud Code API")
        
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: quota.models,
            accountEmail: activeCredentials.email ?? quota.email,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        return self.makeResult(usage: usage, sourceLabel: sourceLabel)
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        let usageSource = context.settings?.antigravity?.usageSource ?? .auto

        if usageSource == .auto {
            return true
        }

        if let oauthError = error as? AntigravityOAuthCredentialsError {
            switch oauthError {
            case .invalidGrant, .notFound:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func resolveCredentials(context: ProviderFetchContext) async throws
        -> (accountLabel: String, credentials: AntigravityOAuthCredentials, sourceLabel: String)
    {
        guard let accountLabel = context.settings?.antigravity?.accountLabel,
              let normalized = AntigravityOAuthCredentialsStore.normalizedLabel(accountLabel)
        else {
            throw AntigravityOAuthCredentialsError.notFound
        }

        if let manualCredentials = self.loadManualCredentials(accountLabel: accountLabel, context: context) {
            return (normalized, manualCredentials, "Manual")
        }

        guard let cached = AntigravityOAuthCredentialsStore.load(accountLabel: normalized) else {
            throw AntigravityOAuthCredentialsError.notFound
        }

        if cached.accessToken.isEmpty, !cached.isRefreshable {
            throw AntigravityOAuthCredentialsError.notFound
        }

        return (normalized, cached, "OAuth")
    }

    private func refreshCredentials(_ credentials: AntigravityOAuthCredentials) async throws -> AntigravityOAuthCredentials {
        guard let refreshToken = credentials.refreshToken else {
            throw AntigravityOAuthCredentialsError.invalidGrant
        }

        return try await AntigravityTokenRefresher.buildCredentialsFromRefreshToken(
            refreshToken: refreshToken,
            fallbackEmail: credentials.email)
    }

    private func loadManualCredentials(
        accountLabel: String,
        context: ProviderFetchContext
    ) -> AntigravityOAuthCredentials? {
        guard let normalized = AntigravityOAuthCredentialsStore.normalizedLabel(accountLabel) else { return nil }

        let tokenAccounts = context.settings?.antigravity?.tokenAccounts
        guard let account = tokenAccounts?.accounts.first(where: { $0.label.lowercased() == normalized }) else {
            return nil
        }

        guard let payload = AntigravityOAuthCredentialsStore.manualTokenPayload(from: account.token) else { return nil }
        return AntigravityOAuthCredentials(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: nil,
            email: account.label,
            scopes: [])
    }
}
