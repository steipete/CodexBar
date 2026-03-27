import Foundation

public struct RefreshOutcome: Sendable {
    public let snapshot: WidgetSnapshot
    public let errors: [UsageProvider: String]

    public init(snapshot: WidgetSnapshot, errors: [UsageProvider: String]) {
        self.snapshot = snapshot
        self.errors = errors
    }
}

public actor UsageRefreshService {
    public init() {}

    public func refreshAll() async -> RefreshOutcome {
        var entries: [WidgetSnapshot.ProviderEntry] = []
        var enabledProviders: [UsageProvider] = []
        var errors: [UsageProvider: String] = [:]

        do {
            if let credentials = try CredentialsStore.loadCodex(),
               !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                enabledProviders.append(.codex)
                do {
                    let resolved = try await self.resolveCodexCredentials(credentials)
                    let usage = try await self.fetchCodexUsage(with: resolved)
                    entries.append(CodexUsageAPI.makeEntry(response: usage))
                } catch {
                    errors[.codex] = error.localizedDescription
                }
            }
        } catch {
            errors[.codex] = error.localizedDescription
        }

        do {
            let oauthCredentials = try CredentialsStore.loadClaude()
            let webSession = try CredentialsStore.loadClaudeWebSession()
            let hasOAuthCredentials = oauthCredentials?.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasWebSession = webSession?.isValid == true

            if hasOAuthCredentials || hasWebSession
            {
                enabledProviders.append(.claude)
                do {
                    if let oauthCredentials, hasOAuthCredentials {
                        do {
                            let resolved = try await self.resolveClaudeCredentials(oauthCredentials)
                            let usage = try await self.fetchClaudeUsage(with: resolved)
                            entries.append(try ClaudeUsageAPI.makeEntry(response: usage))
                        } catch {
                            guard let webSession, hasWebSession else {
                                throw error
                            }
                            let usage = try await self.fetchClaudeWebUsage(with: webSession)
                            entries.append(try ClaudeWebUsageAPI.makeEntry(response: usage))
                        }
                    } else if let webSession, hasWebSession {
                        let usage = try await self.fetchClaudeWebUsage(with: webSession)
                        entries.append(try ClaudeWebUsageAPI.makeEntry(response: usage))
                    }
                } catch {
                    errors[.claude] = error.localizedDescription
                }
            }
        } catch {
            errors[.claude] = error.localizedDescription
        }

        let snapshot = WidgetSnapshot(
            entries: entries.sorted { $0.provider.rawValue < $1.provider.rawValue },
            enabledProviders: enabledProviders,
            generatedAt: Date())
        WidgetSnapshotStore.save(snapshot)
        return RefreshOutcome(snapshot: snapshot, errors: errors)
    }

    private func resolveCodexCredentials(_ credentials: CodexCredentials) async throws -> CodexCredentials {
        guard credentials.needsRefresh else { return credentials }
        let refreshed = try await CodexOAuthClient.refresh(credentials)
        try CredentialsStore.saveCodex(refreshed)
        return refreshed
    }

    private func fetchCodexUsage(with credentials: CodexCredentials) async throws -> CodexUsageResponse {
        do {
            return try await CodexUsageAPI.fetchUsage(
                accessToken: credentials.accessToken,
                accountID: credentials.accountID)
        } catch CodexUsageAPIError.unauthorized where credentials.canRefresh {
            let refreshed = try await CodexOAuthClient.refresh(credentials)
            try CredentialsStore.saveCodex(refreshed)
            return try await CodexUsageAPI.fetchUsage(
                accessToken: refreshed.accessToken,
                accountID: refreshed.accountID)
        }
    }

    private func resolveClaudeCredentials(_ credentials: ClaudeCredentials) async throws -> ClaudeCredentials {
        guard credentials.isExpired, credentials.canRefresh else { return credentials }
        let refreshed = try await ClaudeOAuthClient.refresh(credentials)
        try CredentialsStore.saveClaude(refreshed)
        return refreshed
    }

    private func fetchClaudeUsage(with credentials: ClaudeCredentials) async throws -> ClaudeOAuthUsageResponse {
        do {
            return try await ClaudeUsageAPI.fetchUsage(accessToken: credentials.accessToken)
        } catch ClaudeUsageAPIError.unauthorized where credentials.canRefresh {
            let refreshed = try await ClaudeOAuthClient.refresh(credentials)
            try CredentialsStore.saveClaude(refreshed)
            return try await ClaudeUsageAPI.fetchUsage(accessToken: refreshed.accessToken)
        }
    }

    private func fetchClaudeWebUsage(with session: ClaudeWebSession) async throws -> ClaudeOAuthUsageResponse {
        do {
            return try await ClaudeWebUsageAPI.fetchUsage(sessionKey: session.sessionKey)
        } catch ClaudeWebUsageAPIError.unauthorized {
            try? CredentialsStore.deleteClaudeWebSession()
            throw ClaudeWebUsageAPIError.unauthorized
        }
    }
}
