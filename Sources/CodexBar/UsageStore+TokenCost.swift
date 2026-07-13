import CodexBarCore
import Foundation

extension UsageStore {
    func loadTokenUsageSnapshot(
        provider: UsageProvider,
        force: Bool,
        now: Date,
        codexHomePath: String?,
        historyDays: Int) async throws -> CostUsageTokenSnapshot
    {
        if let override = self._test_tokenUsageSnapshotLoaderOverride {
            return try await override(provider, force, now, codexHomePath, historyDays)
        }

        let fetcher = self.costUsageFetcher
        let timeoutSeconds = self.tokenFetchTimeout
        let environment = provider == .bedrock
            ? ProviderRegistry.makeEnvironment(
                base: self.environmentBase,
                provider: provider,
                settings: self.settings,
                tokenOverride: nil)
            : self.environmentBase
        return try await withThrowingTaskGroup(of: CostUsageTokenSnapshot.self) { group in
            group.addTask(priority: .utility) {
                try await fetcher.loadTokenSnapshot(
                    provider: provider,
                    environment: environment,
                    now: now,
                    forceRefresh: force,
                    allowVertexClaudeFallback: !self.isEnabled(.claude),
                    codexHomePath: codexHomePath,
                    historyDays: historyDays,
                    bypassScannerDebounce: true)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CostUsageError.timedOut(seconds: Int(timeoutSeconds))
            }
            defer { group.cancelAll() }
            guard let snapshot = try await group.next() else { throw CancellationError() }
            return snapshot
        }
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

    func hydrateCachedTokenSnapshots(now: Date = Date()) {
        guard self.settings.costUsageEnabled else { return }
        guard self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata).contains(.codex) else {
            return
        }

        let scope = self.tokenCostScope(for: .codex)
        let historyDays = self.settings.costUsageHistoryDays
        let publicationRevision = self.providerPublicationRevision(for: .codex)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.tokenSnapshots[.codex] == nil else { return }
            let result: (snapshot: CostUsageTokenSnapshot, lastRefreshAt: Date?)? = if let override = self
                ._test_cachedCodexTokenSnapshotLoaderOverride
            {
                await override(now, scope.codexHomePath, historyDays)
            } else {
                await self.costUsageFetcher.loadCachedCodexTokenSnapshotResult(
                    now: now,
                    codexHomePath: scope.codexHomePath,
                    historyDays: historyDays)
                    .map { (snapshot: $0.snapshot, lastRefreshAt: $0.lastRefreshAt) }
            }
            guard let result
            else {
                return
            }
            guard self.providerPublicationRevisionIsCurrent(publicationRevision, for: .codex),
                  self.settings.costUsageEnabled,
                  self.isEnabled(.codex),
                  self.tokenCostScope(for: .codex).signature == scope.signature,
                  self.settings.costUsageHistoryDays == historyDays,
                  self.tokenSnapshots[.codex] == nil
            else {
                return
            }
            self.tokenSnapshots[.codex] = result.snapshot
            self.tokenErrors[.codex] = nil
            if let lastRefreshAt = result.lastRefreshAt,
               now.timeIntervalSince(lastRefreshAt) >= 0,
               now.timeIntervalSince(lastRefreshAt) < self.tokenFetchTTL
            {
                self.lastTokenFetchAt[.codex] = lastRefreshAt
                self.lastTokenFetchScope[.codex] = "\(scope.signature)|historyDays=\(historyDays)"
            }
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

    func clearCostUsageCache() async -> String? {
        let errorMessage: String? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let cacheDirs = [
                Self.costUsageCacheDirectory(fileManager: fm),
            ]

            for cacheDir in cacheDirs {
                do {
                    try fm.removeItem(at: cacheDir)
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                        continue
                    }
                    return error.localizedDescription
                }
            }
            return nil
        }.value

        guard errorMessage == nil else { return errorMessage }

        self.tokenSnapshots.removeAll()
        self.tokenErrors.removeAll()
        self.lastTokenFetchAt.removeAll()
        self.lastTokenFetchScope.removeAll()
        self.tokenFailureGates[.codex]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        return nil
    }

    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.noDataMessage()
    }
}
