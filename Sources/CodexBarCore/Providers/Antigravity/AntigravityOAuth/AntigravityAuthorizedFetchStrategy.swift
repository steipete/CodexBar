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

        Self.log.debug(
            """
            Keychain credentials found - hasAccessToken: \(!credentials.accessToken.isEmpty), \
            isRefreshable: \(credentials.isRefreshable)
            """)

        if !credentials.accessToken.isEmpty { return true }
        return credentials.isRefreshable
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        Self.log.debug("Fetching with authorized strategy")

        let resolved = try await self.resolveCredentials(context: context)
        let accountLabel = resolved.accountLabel
        var credentials = resolved.credentials
        let sourceLabel = resolved.sourceLabel
        var didRefresh = false

        Self.log.debug(
            """
            Resolved credentials - source: \(sourceLabel), needsRefresh: \(credentials.needsRefresh), \
            isRefreshable: \(credentials.isRefreshable)
            """)

        if credentials.needsRefresh || (credentials.accessToken.isEmpty && credentials.isRefreshable) {
            Self.log.debug("Credentials need refresh, refreshing token...")
            credentials = try await self.refreshAndSave(credentials, accountLabel: accountLabel, context: context)
            didRefresh = true
            Self.log.debug("Token refresh successful")
        }

        do {
            return try await self.fetchQuotaAndMakeResult(credentials: credentials, sourceLabel: sourceLabel)
        } catch AntigravityOAuthCredentialsError.invalidGrant where credentials.isRefreshable && !didRefresh {
            Self.log.info("API returned invalidGrant, attempting refresh-and-retry")
            credentials = try await self.refreshAndSave(credentials, accountLabel: accountLabel, context: context)
            return try await self.fetchQuotaAndMakeResult(credentials: credentials, sourceLabel: sourceLabel)
        }
    }

    private func fetchQuotaAndMakeResult(
        credentials: AntigravityOAuthCredentials,
        sourceLabel: String) async throws -> ProviderFetchResult
    {
        var projectId: String?
        do {
            let info = try await AntigravityCloudCodeClient.loadProjectInfo(
                accessToken: credentials.accessToken)
            projectId = info.projectId
            Self.log.debug("Bootstrapped project ID: \(projectId ?? "nil")")
        } catch AntigravityOAuthCredentialsError.invalidGrant {
            throw AntigravityOAuthCredentialsError.invalidGrant
        } catch {
            Self.log.info("Project bootstrap failed (non-fatal): \(error.localizedDescription)")
        }

        let quota: AntigravityCloudCodeQuota
        do {
            let primary = try await AntigravityCloudCodeClient.fetchQuota(
                accessToken: credentials.accessToken,
                projectId: projectId)
            if primary.models.isEmpty {
                Self.log.info("fetchAvailableModels returned empty models, trying retrieveUserQuota")
                quota = try await AntigravityCloudCodeClient.retrieveUserQuota(
                    accessToken: credentials.accessToken,
                    projectId: projectId)
            } else {
                quota = primary
            }
        } catch AntigravityOAuthCredentialsError.invalidGrant {
            throw AntigravityOAuthCredentialsError.invalidGrant
        } catch let primaryError {
            Self.log.info("fetchAvailableModels failed, trying retrieveUserQuota: \(primaryError.localizedDescription)")
            do {
                quota = try await AntigravityCloudCodeClient.retrieveUserQuota(
                    accessToken: credentials.accessToken,
                    projectId: projectId)
            } catch {
                Self.log.warning("retrieveUserQuota fallback also failed: \(error.localizedDescription)")
                throw primaryError
            }
        }

        Self.log.debug("Successfully fetched quota from Cloud Code API")

        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: quota.models,
            accountEmail: credentials.email ?? quota.email,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        return self.makeResult(usage: usage, sourceLabel: sourceLabel)
    }

    private func refreshAndSave(
        _ credentials: AntigravityOAuthCredentials,
        accountLabel: String,
        context: ProviderFetchContext) async throws -> AntigravityOAuthCredentials
    {
        do {
            let refreshed = try await self.refreshCredentials(credentials)

            if KeychainAccessGate.isDisabled {
                context.onAntigravityCredentialsRefreshed?(accountLabel, refreshed)
            } else {
                _ = AntigravityOAuthCredentialsStore.save(refreshed, accountLabel: accountLabel)
            }

            return refreshed
        } catch AntigravityOAuthCredentialsError.invalidGrant {
            Self.log.warning("Refresh token invalid, clearing keychain credentials")
            if !KeychainAccessGate.isDisabled {
                AntigravityOAuthCredentialsStore.clear(accountLabel: accountLabel)
            }
            throw AntigravityOAuthCredentialsError.invalidGrant
        }
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
            case .permissionDenied:
                return false
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

    private func refreshCredentials(_ credentials: AntigravityOAuthCredentials) async throws
    -> AntigravityOAuthCredentials {
        guard let refreshToken = credentials.refreshToken else {
            throw AntigravityOAuthCredentialsError.invalidGrant
        }

        return try await AntigravityTokenRefresher.buildCredentialsFromRefreshToken(
            refreshToken: refreshToken,
            fallbackEmail: credentials.email)
    }

    private func loadManualCredentials(
        accountLabel: String,
        context: ProviderFetchContext) -> AntigravityOAuthCredentials?
    {
        guard let normalized = AntigravityOAuthCredentialsStore.normalizedLabel(accountLabel) else { return nil }

        let tokenAccounts = context.settings?.antigravity?.tokenAccounts
        guard let account = tokenAccounts?.accounts.first(where: { $0.label.lowercased() == normalized }) else {
            return nil
        }

        guard let payload = AntigravityOAuthCredentialsStore.manualTokenPayload(from: account.token) else { return nil }
        return AntigravityOAuthCredentials(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: payload.expiresAt,
            email: account.label,
            scopes: [])
    }
}
