import Foundation

public enum MiniMaxDiagnosticExportBuilder {
    public static func build(
        outcome: ProviderFetchOutcome,
        settings: ProviderSettingsSnapshot?,
        authMode: MiniMaxAuthMode) -> MiniMaxDiagnosticExport
    {
        let sourceLabel = outcome.sourceLabel
        let authConfigured = outcome.authConfigured(authMode: authMode)
        let usage = outcome.usageSnapshot.map { MiniMaxDiagnosticUsage(from: $0) }
        let error = outcome.failureError.map { MiniMaxDiagnosticError(from: $0) }

        let settingsSummary = MiniMaxSettingsSummary(
            apiRegion: settings?.minimax?.apiRegion.rawValue ?? "global",
            authMode: authMode.description)

        return MiniMaxDiagnosticExport(
            timestamp: Date(),
            provider: "minimax",
            source: sourceLabel,
            authMode: authMode.description,
            authConfigured: authConfigured,
            usage: usage,
            fetchAttempts: outcome.attempts.map { MiniMaxDiagnosticFetchAttempt(from: $0) },
            error: error,
            settingsSummary: settingsSummary)
    }
}

extension ProviderFetchOutcome {
    fileprivate var sourceLabel: String {
        guard case let .success(result) = result else { return "failed" }
        return result.sourceLabel
    }

    fileprivate func authConfigured(authMode: MiniMaxAuthMode) -> Bool {
        guard case .success = result else { return authMode.usesAPIToken || authMode.usesCookie }
        return true
    }

    fileprivate var usageSnapshot: MiniMaxUsageSnapshot? {
        guard case let .success(result) = result else { return nil }
        return result.usage.minimaxUsage
    }

    fileprivate var failureError: Error? {
        guard case let .failure(error) = result else { return nil }
        return error
    }
}
