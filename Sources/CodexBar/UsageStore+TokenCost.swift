import CodexBarCore
import Foundation

extension UsageStore {
    /// Codex `…/sessions` directory for the credentials dir selected in Settings (path-based token accounts), or `nil` to use the process environment / `~/.codex`.
    func codexCostUsageSessionsRootForActiveSelection() -> URL? {
        guard let support = TokenAccountSupportCatalog.support(for: .codex),
              case .codexHome = support.injection
        else { return nil }
        let data = self.settings.tokenAccountsData(for: .codex)
        let defaultActive = data?.isDefaultActive ?? true
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
