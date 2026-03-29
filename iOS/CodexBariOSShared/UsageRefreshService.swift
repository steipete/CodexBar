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
        let previousSnapshot = WidgetSnapshotStore.load()
        var entriesByProvider = Dictionary(
            uniqueKeysWithValues: (previousSnapshot?.entries ?? []).map { ($0.provider, $0) })
        var enabledProviders: [UsageProvider] = []
        var errors: [UsageProvider: String] = [:]
        var didUpdateAnyEntry = false

        do {
            if let credentials = try CredentialsStore.loadCodex(),
               !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Self.appendEnabledProvider(.codex, to: &enabledProviders)
                do {
                    let resolved = try await self.resolveCodexCredentials(credentials)
                    let usage = try await self.fetchCodexUsage(with: resolved)
                    entriesByProvider[.codex] = CodexUsageAPI.makeEntry(response: usage)
                    didUpdateAnyEntry = true
                } catch {
                    if !Self.isCancellation(error) {
                        entriesByProvider.removeValue(forKey: .codex)
                        errors[.codex] = error.localizedDescription
                    }
                }
            }
        } catch {
            entriesByProvider.removeValue(forKey: .codex)
            errors[.codex] = error.localizedDescription
        }

        do {
            let oauthCredentials = try CredentialsStore.loadClaude()
            let webSession = try CredentialsStore.loadClaudeWebSession()
            let hasOAuthCredentials = oauthCredentials?.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasWebSession = webSession?.isValid == true

            if hasOAuthCredentials || hasWebSession
            {
                Self.appendEnabledProvider(.claude, to: &enabledProviders)
                do {
                    if let oauthCredentials, hasOAuthCredentials {
                        do {
                            let resolved = try await self.resolveClaudeCredentials(oauthCredentials)
                            let usage = try await self.fetchClaudeUsage(with: resolved)
                            entriesByProvider[.claude] = try ClaudeUsageAPI.makeEntry(response: usage)
                            didUpdateAnyEntry = true
                        } catch {
                            guard let webSession, hasWebSession else {
                                throw error
                            }
                            let usage = try await self.fetchClaudeWebUsage(with: webSession)
                            entriesByProvider[.claude] = try ClaudeWebUsageAPI.makeEntry(response: usage)
                            didUpdateAnyEntry = true
                        }
                    } else if let webSession, hasWebSession {
                        let usage = try await self.fetchClaudeWebUsage(with: webSession)
                        entriesByProvider[.claude] = try ClaudeWebUsageAPI.makeEntry(response: usage)
                        didUpdateAnyEntry = true
                    }
                } catch {
                    if !Self.isCancellation(error) {
                        entriesByProvider.removeValue(forKey: .claude)
                        errors[.claude] = error.localizedDescription
                    }
                }
            }
        } catch {
            entriesByProvider.removeValue(forKey: .claude)
            errors[.claude] = error.localizedDescription
        }

        let snapshot = Self.mergedSnapshot(
            previousSnapshot: previousSnapshot,
            enabledProviders: enabledProviders,
            entriesByProvider: entriesByProvider,
            didUpdateAnyEntry: didUpdateAnyEntry)
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

    static func mergedSnapshot(
        previousSnapshot: WidgetSnapshot?,
        enabledProviders: [UsageProvider],
        entriesByProvider: [UsageProvider: WidgetSnapshot.ProviderEntry],
        didUpdateAnyEntry: Bool) -> WidgetSnapshot
    {
        let normalizedEnabledProviders = enabledProviders.reduce(into: [UsageProvider]()) { partialResult, provider in
            if !partialResult.contains(provider) {
                partialResult.append(provider)
            }
        }

        let generatedAt = didUpdateAnyEntry ? Date() : (previousSnapshot?.generatedAt ?? Date())

        return WidgetSnapshot(
            entries: normalizedEnabledProviders.compactMap { entriesByProvider[$0] },
            enabledProviders: normalizedEnabledProviders,
            generatedAt: generatedAt)
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }

        switch error {
        case let CodexUsageAPIError.networkError(underlying):
            return Self.isCancellation(underlying)
        case let ClaudeUsageAPIError.networkError(underlying):
            return Self.isCancellation(underlying)
        case let ClaudeWebUsageAPIError.networkError(underlying):
            return Self.isCancellation(underlying)
        case let CodexOAuthClientError.networkError(underlying):
            return Self.isCancellation(underlying)
        case let ClaudeOAuthClientError.networkError(underlying):
            return Self.isCancellation(underlying)
        default:
            return false
        }
    }

    private static func appendEnabledProvider(_ provider: UsageProvider, to enabledProviders: inout [UsageProvider]) {
        if !enabledProviders.contains(provider) {
            enabledProviders.append(provider)
        }
    }
}
