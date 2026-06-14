import Foundation

public enum BorrowedCredentialError: LocalizedError, Equatable, Sendable {
    case expired(accountID: String)

    public var errorDescription: String? {
        switch self {
        case let .expired(accountID):
            "Imported Codex credential expired for \(accountID). Refresh it in the source tool."
        }
    }
}

public enum BorrowedCodexUsageFetcher {
    private static let fetchEnvironment = [
        "CODEX_HOME": "/var/empty/codexbar-borrowed-codex",
    ]

    public static func fetchUsage(
        account: BorrowedCodexAccount,
        updatedAt: Date) async throws -> ProviderFetchResult
    {
        guard !account.isExpired else {
            throw BorrowedCredentialError.expired(accountID: account.id)
        }

        let usageResponse = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: account.credentials.accessToken,
            accountId: account.accountId,
            env: self.fetchEnvironment)
        return try self.makeResult(
            usageResponse: usageResponse,
            credentials: account.credentials,
            updatedAt: updatedAt)
    }

    private static func makeResult(
        usageResponse: CodexUsageResponse,
        credentials: CodexOAuthCredentials,
        updatedAt: Date) throws -> ProviderFetchResult
    {
        let credits = self.mapCredits(usageResponse.credits, updatedAt: updatedAt)
        let reconciled = CodexReconciledState.fromOAuth(
            response: usageResponse,
            credentials: credentials,
            updatedAt: updatedAt)

        if let reconciled {
            return ProviderFetchResult(
                usage: reconciled.toUsageSnapshot(),
                credits: credits,
                dashboard: nil,
                sourceLabel: "borrowed",
                strategyID: "codex.borrowed",
                strategyKind: .oauth)
        }

        guard let credits else {
            throw UsageError.noRateLimitsFound
        }

        return ProviderFetchResult(
            usage: UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                updatedAt: updatedAt,
                identity: CodexReconciledState.oauthIdentity(
                    response: usageResponse,
                    credentials: credentials)),
            credits: credits,
            dashboard: nil,
            sourceLabel: "borrowed",
            strategyID: "codex.borrowed",
            strategyKind: .oauth)
    }

    private static func mapCredits(
        _ credits: CodexUsageResponse.CreditDetails?,
        updatedAt: Date) -> CreditsSnapshot?
    {
        guard let credits, let balance = credits.balance else { return nil }
        return CreditsSnapshot(remaining: balance, events: [], updatedAt: updatedAt)
    }
}
