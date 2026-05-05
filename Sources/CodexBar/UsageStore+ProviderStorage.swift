import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    private struct StorageRefreshRequest {
        let providers: [UsageProvider]
        let candidatePathsByProvider: [UsageProvider: [String]]
        let signature: String
    }

    private static let automaticStorageRefreshInterval: TimeInterval = 5 * 60

    var isStorageRefreshInFlight: Bool {
        self.storageRefreshTask != nil
    }

    func storageFootprint(for provider: UsageProvider) -> ProviderStorageFootprint? {
        guard self.settings.providerStorageFootprintsEnabled else { return nil }
        return self.providerStorageFootprints[provider]
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

    func scheduleStorageFootprintRefreshForOverview(force: Bool = false) {
        self.scheduleStorageFootprintRefresh(for: self.enabledProvidersForDisplay(), force: force)
    }

    func refreshStorageFootprintsNow(for providers: [UsageProvider]) async {
        guard self.settings.providerStorageFootprintsEnabled else {
            self.clearStorageFootprints()
            return
        }
        guard let request = self.makeStorageRefreshRequest(for: providers) else {
            self.clearStorageFootprints()
            return
        }

        self.storageRefreshTask?.cancel()
        self.storageRefreshGeneration &+= 1
        let generation = self.storageRefreshGeneration
        self.storageRefreshInFlightSignature = request.signature

        let footprints = await Task.detached(priority: .utility) {
            Self.scanStorageFootprints(candidatePathsByProvider: request.candidatePathsByProvider)
        }.value

        guard generation == self.storageRefreshGeneration else { return }
        self.applyStorageFootprints(
            footprints,
            providers: request.providers,
            signature: request.signature,
            updatedAt: Date())
        self.storageRefreshTask = nil
        self.storageRefreshInFlightSignature = nil
    }

    func scheduleStorageFootprintRefresh(for providers: [UsageProvider], force: Bool = false) {
        guard self.settings.providerStorageFootprintsEnabled else {
            self.clearStorageFootprints()
            return
        }
        guard let request = self.makeStorageRefreshRequest(for: providers) else {
            self.clearStorageFootprints()
            return
        }

        let now = Date()
        if !force {
            if self.storageRefreshTask != nil,
               self.storageRefreshInFlightSignature == request.signature
            {
                return
            }
            if self.lastStorageRefreshSignature == request.signature,
               let lastStorageRefreshAt,
               now.timeIntervalSince(lastStorageRefreshAt) < Self.automaticStorageRefreshInterval
            {
                return
            }
        }

        self.storageRefreshTask?.cancel()
        self.storageRefreshGeneration &+= 1
        let generation = self.storageRefreshGeneration
        self.storageRefreshInFlightSignature = request.signature

        self.storageRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let footprints = Self.scanStorageFootprints(candidatePathsByProvider: request.candidatePathsByProvider)

            await MainActor.run { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      generation == self.storageRefreshGeneration
                else { return }

                self.applyStorageFootprints(
                    footprints,
                    providers: request.providers,
                    signature: request.signature,
                    updatedAt: Date())
                self.storageRefreshTask = nil
                self.storageRefreshInFlightSignature = nil
            }
        }
    }

    private func clearStorageFootprints() {
        self.storageRefreshTask?.cancel()
        self.storageRefreshTask = nil
        self.storageRefreshInFlightSignature = nil
        self.lastStorageRefreshSignature = nil
        self.lastStorageRefreshAt = nil
        self.providerStorageFootprints.removeAll()
    }

    private func applyStorageFootprints(
        _ footprints: [UsageProvider: ProviderStorageFootprint],
        providers: [UsageProvider],
        signature: String,
        updatedAt: Date)
    {
        let providerSet = Set(providers)
        self.providerStorageFootprints = self.providerStorageFootprints.filter { !providerSet.contains($0.key) }
        for provider in providers {
            self.providerStorageFootprints[provider] = footprints[provider]
        }
        self.lastStorageRefreshSignature = signature
        self.lastStorageRefreshAt = updatedAt
    }

    private func makeStorageRefreshRequest(for providers: [UsageProvider]) -> StorageRefreshRequest? {
        let uniqueProviders = Array(Set(providers)).sorted { $0.rawValue < $1.rawValue }
        guard !uniqueProviders.isEmpty else { return nil }

        let environment = self.environmentBase
        let managedAccounts = self.loadManagedCodexAccountsForStorage()
        var candidatePathsByProvider: [UsageProvider: [String]] = [:]

        for provider in uniqueProviders {
            let candidatePaths = ProviderStoragePathCatalog.candidatePaths(
                for: provider,
                environment: environment,
                managedCodexAccounts: managedAccounts)
            guard !candidatePaths.isEmpty else { continue }
            candidatePathsByProvider[provider] = candidatePaths
        }

        let providersWithPaths = uniqueProviders.filter { candidatePathsByProvider[$0] != nil }
        guard !providersWithPaths.isEmpty else { return nil }

        let signature = providersWithPaths
            .map { provider in
                let paths = candidatePathsByProvider[provider]?.joined(separator: "\u{1f}") ?? ""
                return "\(provider.rawValue)=\(paths)"
            }
            .joined(separator: "\u{1e}")
        return StorageRefreshRequest(
            providers: providersWithPaths,
            candidatePathsByProvider: candidatePathsByProvider,
            signature: signature)
    }

    private func loadManagedCodexAccountsForStorage() -> [ManagedCodexAccount] {
        if let managedCodexAccountsForStorageOverride {
            return managedCodexAccountsForStorageOverride
        }
        return (try? FileManagedCodexAccountStore().loadAccounts().accounts) ?? []
    }

    private nonisolated static func scanStorageFootprints(
        candidatePathsByProvider: [UsageProvider: [String]])
        -> [UsageProvider: ProviderStorageFootprint]
    {
        let scanner = ProviderStorageScanner()
        var footprints: [UsageProvider: ProviderStorageFootprint] = [:]
        var pathCache: [String: ProviderStorageFootprint] = [:]

        for provider in candidatePathsByProvider.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if Task.isCancelled { return footprints }
            guard let candidatePaths = candidatePathsByProvider[provider] else { continue }
            let pathKey = candidatePaths.joined(separator: "\u{1f}")
            if let cached = pathCache[pathKey] {
                footprints[provider] = cached.replacingProvider(provider)
                continue
            }
            let footprint = scanner.scan(provider: provider, candidatePaths: candidatePaths)
            pathCache[pathKey] = footprint
            footprints[provider] = footprint
        }

        return footprints
    }
}
