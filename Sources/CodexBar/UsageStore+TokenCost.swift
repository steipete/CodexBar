import CodexBarCore
import Foundation

extension UsageStore {
    func tokenSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        guard let snapshot = self.tokenSnapshots[provider] else { return nil }
        guard provider == .codex else { return snapshot }
        guard let snapshotScope = self.tokenSnapshotScopes[provider] else { return snapshot }
        return snapshotScope == self.tokenCostScopeSignature(for: provider) ? snapshot : nil
    }

    func tokenError(for provider: UsageProvider) -> String? {
        guard let error = self.tokenErrors[provider] else { return nil }
        guard provider == .codex else { return error }
        guard let errorScope = self.tokenErrorScopes[provider] else { return error }
        return errorScope == self.tokenCostScopeSignature(for: provider) ? error : nil
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider]
    }

    func isTokenRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider)
    }

    func tokenCostScope(for provider: UsageProvider) -> (codexHomePath: String?, signature: String) {
        guard provider == .codex else {
            return (nil, provider.rawValue)
        }
        let homePath = self.settings.activeManagedCodexRemoteHomePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let homePath, !homePath.isEmpty else {
            return (nil, "codex:ambient")
        }
        return (homePath, "codex:managed:\(homePath)")
    }

    func tokenCostScopeSignature(for provider: UsageProvider) -> String {
        let scope = self.tokenCostScope(for: provider)
        return "\(scope.signature)|historyDays=\(self.settings.costUsageHistoryDays)"
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
