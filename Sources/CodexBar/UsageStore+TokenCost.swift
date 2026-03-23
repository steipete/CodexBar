import CodexBarCore
import Foundation

extension UsageStore {
    /// Codex `…/sessions` directory for the credentials dir selected in Settings (path-based token accounts), or `nil`
    /// to use the process environment / `~/.codex`.
    /// Whether cost data should be suppressed because "CodexBar accounts only" is on
    /// and no explicit account is selected (would otherwise fall back to ~/.codex).
    var shouldSuppressDefaultCostData: Bool {
        guard self.settings.codexExplicitAccountsOnly else { return false }
        let defaultActive = self.settings.isDefaultTokenAccountActive(for: .codex)
        if defaultActive { return true }
        return self.settings.selectedTokenAccount(for: .codex) == nil
    }

    /// True when the currently selected Codex account uses an API key ("apikey:" prefix).
    /// API-key accounts have no local session logs, so session-based cost data does not apply
    /// and falling back to ~/.codex would leak the primary account's cost totals.
    var isActiveCodexAccountApiKey: Bool {
        guard let account = self.settings.selectedTokenAccount(for: .codex) else { return false }
        let token = account.token.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.lowercased().hasPrefix("apikey:")
    }

    func codexCostUsageSessionsRootForActiveSelection() -> URL? {
        guard let support = TokenAccountSupportCatalog.support(for: .codex),
              case .codexHome = support.injection
        else { return nil }
        let defaultActive = self.settings.isDefaultTokenAccountActive(for: .codex)
        if defaultActive { return nil }
        guard let account = self.settings.selectedTokenAccount(for: .codex) else { return nil }
        let token = account.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiPrefix = "apikey:"
        if token.lowercased().hasPrefix(apiPrefix) { return nil }
        let expanded = (token as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded).appendingPathComponent("sessions", isDirectory: true)
    }

    /// Stable key for the local logs backing token-cost; when it changes, cached cost data must refresh.
    func tokenCostSelectionIdentity(for provider: UsageProvider) -> String {
        if provider == .codex {
            if let root = self.codexCostUsageSessionsRootForActiveSelection() {
                return root.path
            }
            return "codex:default"
        }
        return "\(provider.rawValue):default"
    }

    func tokenSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        self.tokenSnapshots[provider]
    }

    func tokenError(for provider: UsageProvider) -> String? {
        self.tokenErrors[provider]
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider]
    }

    func isTokenRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider)
    }

    nonisolated static func costUsageCacheDirectory(
        fileManager: FileManager = .default) -> URL
    {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
    }

    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.noDataMessage()
    }
}
