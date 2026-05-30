import CodexBarCore
import Foundation

extension UsageStore {
    func tokenSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        self.tokenSnapshots[provider]
    }

    func tokenError(for provider: UsageProvider) -> String? {
        self.tokenErrors[provider]
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider]
    }

    func hydrateCachedTokenSnapshots(now: Date = Date()) {
        guard self.settings.costUsageEnabled else { return }
        guard self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata).contains(.codex) else {
            return
        }

        let scope = self.tokenCostScope(for: .codex)
        let historyDays = self.settings.costUsageHistoryDays
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.tokenSnapshots[.codex] == nil else { return }
            guard let snapshot = await self.costUsageFetcher.loadCachedCodexTokenSnapshot(
                now: now,
                codexHomePath: scope.codexHomePath,
                historyDays: historyDays)
            else {
                return
            }
            guard self.settings.costUsageEnabled,
                  self.isEnabled(.codex),
                  self.tokenCostScope(for: .codex).signature == scope.signature,
                  self.tokenSnapshots[.codex] == nil
            else {
                return
            }
            self.tokenSnapshots[.codex] = snapshot
            self.tokenErrors[.codex] = nil
        }
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

    func tokenSnapshot(
        fromProviderSnapshot snapshot: UsageSnapshot?,
        provider: UsageProvider)
        -> CostUsageTokenSnapshot?
    {
        switch provider {
        case .openai:
            snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot()
        case .mistral:
            snapshot?.mistralUsage?.toCostUsageTokenSnapshot(historyDays: self.settings.costUsageHistoryDays)
        default:
            nil
        }
    }

    nonisolated static func tokenCostRequiresProviderSnapshot(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .mistral, .openai:
            true
        default:
            false
        }
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
