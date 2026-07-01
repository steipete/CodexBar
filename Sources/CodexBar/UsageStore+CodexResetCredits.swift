import CodexBarCore
import Foundation

extension UsageStore {
    typealias CodexResetCreditsFetcher = @Sendable ([String: String]) async throws
        -> CodexRateLimitResetCreditsSnapshot?

    func codexResetCreditsFetcher() -> CodexResetCreditsFetcher {
        if let override = self._test_codexResetCreditsFetcherOverride {
            return override
        }
        return { env in
            try await Self.fetchCodexResetCredits(env: env)
        }
    }

    func handleCodexResetCreditNotifications(snapshot: UsageSnapshot) {
        guard self.settings.showOptionalCreditsAndExtraUsage,
              let resetCredits = snapshot.codexResetCredits
        else {
            return
        }
        CodexResetCreditExpiryNotifier().postExpiringCreditsIfNeeded(
            snapshot: resetCredits,
            resetStyle: self.settings.resetTimeDisplayStyle)
    }

    nonisolated static func attachingCodexResetCreditsIfNeeded(
        to outcome: ProviderFetchOutcome,
        env: [String: String],
        includeOptionalUsage: Bool,
        fetcher: @escaping CodexResetCreditsFetcher) async -> ProviderFetchOutcome
    {
        guard case let .success(result) = outcome.result else { return outcome }
        guard includeOptionalUsage else {
            return outcome.replacingUsage(result.usage.withCodexResetCredits(nil))
        }
        if result.usage.codexResetCredits != nil {
            return outcome
        }

        do {
            try Task.checkCancellation()
            let resetCredits = try await fetcher(env)
            try Task.checkCancellation()
            return outcome.replacingUsage(result.usage.withCodexResetCredits(resetCredits))
        } catch {
            if error is CancellationError || Task.isCancelled {
                return ProviderFetchOutcome(result: .failure(CancellationError()), attempts: outcome.attempts)
            }
            // A successful usage refresh must not retain reset-credit inventory from an older snapshot.
            return outcome.replacingUsage(result.usage.withCodexResetCredits(nil))
        }
    }

    nonisolated static func fetchCodexResetCredits(
        env: [String: String]) async throws -> CodexRateLimitResetCreditsSnapshot?
    {
        try Task.checkCancellation()
        var credentials = try CodexOAuthCredentialsStore.loadOAuthTokens(env: env)
        if credentials.needsRefresh, !credentials.refreshToken.isEmpty {
            credentials = try await CodexTokenRefresher.refresh(credentials)
            try Task.checkCancellation()
            try CodexOAuthCredentialsStore.save(credentials, env: env)
        }
        return try await CodexOAuthUsageFetcher.fetchRateLimitResetCredits(
            accessToken: credentials.accessToken,
            accountId: credentials.accountId,
            env: env)
    }
}

extension ProviderFetchOutcome {
    fileprivate func replacingUsage(_ usage: UsageSnapshot) -> ProviderFetchOutcome {
        guard case let .success(result) = self.result else { return self }
        return ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: usage,
                credits: result.credits,
                dashboard: result.dashboard,
                sourceLabel: result.sourceLabel,
                strategyID: result.strategyID,
                strategyKind: result.strategyKind,
                claudeOAuthKeychainPersistentRefHash: result.claudeOAuthKeychainPersistentRefHash,
                claudeOAuthHistoryOwnerIdentifier: result.claudeOAuthHistoryOwnerIdentifier)),
            attempts: self.attempts)
    }
}
