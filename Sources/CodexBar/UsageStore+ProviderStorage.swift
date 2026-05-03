import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func storageFootprint(for provider: UsageProvider) -> ProviderStorageFootprint? {
        self.providerStorageFootprints[provider]
    }

    func storageFootprintText(for provider: UsageProvider) -> String? {
        guard let footprint = self.storageFootprint(for: provider) else { return nil }
        if footprint.hasLocalData {
            return UsageFormatter.byteCountString(footprint.totalBytes)
        }
        return "No local data found"
    }

    func refreshStorageFootprintsForOverview() {
        self.scheduleStorageFootprintRefresh(for: self.enabledProvidersForDisplay())
    }

    func refreshStorageFootprintsForOverviewNow() async {
        await self.refreshStorageFootprintsNow(for: self.enabledProvidersForDisplay())
    }

    func refreshStorageFootprintsNow(for providers: [UsageProvider]) async {
        self.storageRefreshTask?.cancel()

        let uniqueProviders = Array(Set(providers)).sorted { $0.rawValue < $1.rawValue }
        guard !uniqueProviders.isEmpty else { return }

        let environment = self.environmentBase
        let managedAccounts = self.loadManagedCodexAccountsForStorage()
        let footprints = await Task.detached(priority: .utility) {
            Self.scanStorageFootprints(
                for: uniqueProviders,
                environment: environment,
                managedAccounts: managedAccounts)
        }.value

        for provider in uniqueProviders {
            self.providerStorageFootprints[provider] = footprints[provider]
        }
    }

    func scheduleStorageFootprintRefresh(for providers: [UsageProvider]) {
        self.storageRefreshTask?.cancel()

        let uniqueProviders = Array(Set(providers)).sorted { $0.rawValue < $1.rawValue }
        let environment = self.environmentBase
        let managedAccounts = self.loadManagedCodexAccountsForStorage()

        self.storageRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let footprints = Self.scanStorageFootprints(
                for: uniqueProviders,
                environment: environment,
                managedAccounts: managedAccounts)

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                for provider in uniqueProviders {
                    self.providerStorageFootprints[provider] = footprints[provider]
                }
            }
        }
    }

    private func loadManagedCodexAccountsForStorage() -> [ManagedCodexAccount] {
        (try? FileManagedCodexAccountStore().loadAccounts().accounts) ?? []
    }

    private nonisolated static func scanStorageFootprints(
        for providers: [UsageProvider],
        environment: [String: String],
        managedAccounts: [ManagedCodexAccount])
        -> [UsageProvider: ProviderStorageFootprint]
    {
        let scanner = ProviderStorageScanner()
        var footprints: [UsageProvider: ProviderStorageFootprint] = [:]

        for provider in providers {
            if Task.isCancelled { return footprints }
            let candidatePaths = ProviderStoragePathCatalog.candidatePaths(
                for: provider,
                environment: environment,
                managedCodexAccounts: managedAccounts)
            footprints[provider] = scanner.scan(provider: provider, candidatePaths: candidatePaths)
        }

        return footprints
    }
}
