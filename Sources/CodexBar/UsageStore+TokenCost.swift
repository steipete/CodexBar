import CodexBarCore
import Foundation

struct CurrentProviderConfigTokenSnapshot: Sendable, Equatable {
    let snapshot: CostUsageTokenSnapshot
    let publicationRevision: UInt64
}

struct CurrentProviderConfigTokenPublication: Sendable, Equatable {
    let snapshot: CostUsageTokenSnapshot?
    let publicationRevision: UInt64
}

struct TokenRefreshPublicationGuard {
    let provider: UsageStore.ProviderPublicationRevision
    let tokenSnapshot: UInt64
    let providerConfig: UInt64
}

struct TokenSnapshotPublication: Sendable, Equatable {
    let snapshot: CostUsageTokenSnapshot?
    let publicationRevision: UInt64
    let providerConfigRevision: UInt64
    let scopeSignature: String
}

extension UsageStore {
    enum CursorCostCookiePreparation {
        case proceed(String?)
        case reject
    }

    func prepareCursorCostCookie(for provider: UsageProvider) -> CursorCostCookiePreparation {
        // Provider-specific by design: Cursor's dashboard cost fetch consumes its manually selected browser cookie.
        guard provider == .cursor, self.settings.cursorCookieSource == .manual else {
            return .proceed(nil)
        }
        guard let header = CookieHeaderNormalizer.normalize(self.settings.cursorCookieHeader) else {
            self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
            self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
            self.clearTokenSnapshot(for: provider)
            self.tokenErrors[provider.instanceID] = "Cursor cost requires a non-empty Manual cookie header."
            self.tokenFailureGates[provider.instanceID]?.reset()
            return .reject
        }
        return .proceed(header)
    }

    func loadTokenUsageSnapshot(
        provider: UsageProvider,
        force: Bool,
        now: Date,
        codexHomePath: String?,
        historyDays: Int,
        cursorCookieHeaderOverride: String? = nil) async throws -> CostUsageTokenSnapshot
    {
        if let override = self._test_tokenUsageSnapshotLoaderOverride {
            return try await override(provider, force, now, codexHomePath, historyDays)
        }

        let fetcher = self.costUsageFetcher
        let timeoutSeconds = self.tokenFetchTimeout
        // Provider-specific by design: the Codex ledger owns pricing refresh while Bedrock resolves AWS environment.
        let allowPricingRefresh = provider != .codex || !self.settings.codexLocalSessionCostLedgerEnabled
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
                    cursorCookieHeaderOverride: cursorCookieHeaderOverride,
                    allowPricingRefresh: allowPricingRefresh,
                    bypassScannerDebounce: true,
                    calendar: self.settings.costUsageBucketCalendar)
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
        self.accountScopedTokenSnapshot(for: provider)
    }

    func tokenSnapshotForCurrentProviderConfig(
        for provider: UsageProvider) -> CurrentProviderConfigTokenSnapshot?
    {
        guard let publication = self.tokenSnapshotPublicationForCurrentProviderConfig(for: provider),
              let snapshot = publication.snapshot
        else { return nil }
        return CurrentProviderConfigTokenSnapshot(
            snapshot: snapshot,
            publicationRevision: publication.publicationRevision)
    }

    func tokenSnapshotPublicationForCurrentProviderConfig(
        for provider: UsageProvider) -> CurrentProviderConfigTokenPublication?
    {
        guard let publication = self.tokenSnapshotPublications[provider.instanceID],
              publication.providerConfigRevision == self.settings.providerConfigRevision(for: provider),
              publication.scopeSignature == self.tokenSnapshotScopeSignature(for: provider)
        else { return nil }
        return CurrentProviderConfigTokenPublication(
            snapshot: publication.snapshot, publicationRevision: publication.publicationRevision)
    }

    func tokenSnapshotPublicationRevision(for provider: UsageProvider) -> UInt64 {
        self.tokenSnapshotPublicationRevisions[provider.instanceID] ?? 0
    }

    func tokenRefreshPublicationGuard(for provider: UsageProvider) -> TokenRefreshPublicationGuard {
        TokenRefreshPublicationGuard(
            provider: self.providerPublicationRevision(for: provider),
            tokenSnapshot: self.tokenSnapshotPublicationRevision(for: provider),
            providerConfig: self.settings.providerConfigRevision(for: provider))
    }

    func publishTokenSnapshot(_ snapshot: CostUsageTokenSnapshot, for provider: UsageProvider) {
        self.tokenSnapshots[provider.instanceID] = snapshot
        self.publishTokenSnapshotState(snapshot, for: provider)
    }

    func publishConfirmedEmptyTokenSnapshot(for provider: UsageProvider) {
        self.tokenSnapshots.removeValue(forKey: provider.instanceID)
        self.publishTokenSnapshotState(nil, for: provider)
    }

    func invalidateCLIProxyAPICostAttribution(widgetReason: String = "cliproxyapi-removed") {
        self.cancelCodexCostCatchUp()
        self.cancelSpendDashboardCodexCostCatchUp()
        self.spendDashboardCodexCostCatchUpRevision &+= 1
        // Provider-specific by design: invalidating proxy attribution clears both derived provider projections.
        for provider in [UsageProvider.codex, .claude] {
            self.publishConfirmedEmptyTokenSnapshot(for: provider)
            self.tokenErrors[provider.instanceID] = nil
            self.tokenFailureGates[provider.instanceID]?.reset()
            self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
            self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
        }
        self.persistWidgetSnapshot(reason: widgetReason)
    }

    private func publishTokenSnapshotState(_ snapshot: CostUsageTokenSnapshot?, for provider: UsageProvider) {
        self.tokenSnapshotPublicationRevisions[provider.instanceID, default: 0] &+= 1
        self.tokenSnapshotPublications[provider.instanceID] = TokenSnapshotPublication(
            snapshot: snapshot,
            publicationRevision: self.tokenSnapshotPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            scopeSignature: self.tokenSnapshotScopeSignature(for: provider))
        self.synchronizeSharedSpendDashboardAfterTokenPublication(for: provider)
    }

    func installCachedTokenSnapshot(_ snapshot: CostUsageTokenSnapshot, for provider: UsageProvider) {
        self.tokenSnapshots[provider.instanceID] = snapshot
        self.tokenSnapshotPublications[provider.instanceID] = TokenSnapshotPublication(
            snapshot: snapshot,
            publicationRevision: self.tokenSnapshotPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            scopeSignature: self.tokenSnapshotScopeSignature(for: provider))
    }

    func clearTokenSnapshot(for provider: UsageProvider) {
        self.tokenSnapshots.removeValue(forKey: provider.instanceID)
        self.tokenSnapshotPublications.removeValue(forKey: provider.instanceID)
    }

    func clearTokenSnapshots() {
        for provider in UsageProvider.allCases {
            self.tokenSnapshotPublicationRevisions[provider.instanceID, default: 0] &+= 1
        }
        self.tokenSnapshots.removeAll()
        self.tokenSnapshotPublications.removeAll()
        self.spendDashboardTokenPublications.removeAll()
        self.spendDashboardTokenPublicationRevisions.removeAll()
    }

    func installProviderDerivedTokenSnapshot(from snapshot: UsageSnapshot, for provider: UsageProvider) {
        guard Self.tokenCostRequiresProviderSnapshot(provider) else { return }
        if let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: snapshot, provider: provider) {
            self.installCachedTokenSnapshot(tokenSnapshot, for: provider)
        } else {
            self.clearTokenSnapshot(for: provider)
        }
        self.tokenErrors[provider.instanceID] = nil
        self.tokenFailureGates[provider.instanceID]?.recordSuccess()
    }

    func publishProviderDerivedTokenSnapshot(from snapshot: UsageSnapshot, for provider: UsageProvider) {
        guard Self.tokenCostRequiresProviderSnapshot(provider) else { return }
        if let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: snapshot, provider: provider) {
            self.publishTokenSnapshot(tokenSnapshot, for: provider)
            // Provider-specific by design: a prepaid-balance snapshot without a usage chart means
            // analytics failed. Leave the source unpublished so Overview counts it unavailable
            // instead of known-zero spend.
        } else if provider == .xai, XAICostUsageMapping.isAnalyticsUnavailable(snapshot) {
            self.clearTokenSnapshot(for: provider)
        } else {
            self.publishConfirmedEmptyTokenSnapshot(for: provider)
        }
        self.tokenErrors[provider.instanceID] = nil
        self.tokenFailureGates[provider.instanceID]?.recordSuccess()
    }

    func resetProviderDerivedTokenSnapshot(for provider: UsageProvider) {
        guard Self.tokenCostRequiresProviderSnapshot(provider) else { return }
        self.clearTokenSnapshot(for: provider)
        self.tokenErrors[provider.instanceID] = nil
        self.tokenFailureGates[provider.instanceID]?.reset()
    }

    func clearProviderDerivedTokenSnapshot(for provider: UsageProvider) {
        guard Self.tokenCostRequiresProviderSnapshot(provider) else { return }
        self.clearTokenSnapshot(for: provider)
    }

    func tokenError(for provider: UsageProvider) -> String? {
        self.tokenErrors[provider.instanceID]
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider.instanceID]
    }

    @discardableResult
    func hydrateCachedTokenSnapshots(now: Date = Date()) -> Task<Void, Never>? {
        // Provider-specific by design: only the Codex local ledger hydrates a cached snapshot before the first scan.
        guard self.settings.isCostUsageEffectivelyEnabled(for: .codex) else { return nil }
        guard self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata).contains(.codex) else {
            return nil
        }

        let scope = self.tokenCostScope(for: .codex)
        let historyDays = self.settings.costUsageHistoryDays
        let publicationRevision = self.providerPublicationRevision(for: .codex)
        let providerConfigRevision = self.settings.providerConfigRevision(for: .codex)
        let costUsageSettingsRevision = self.settings.costUsageSettingsRevision
        let tokenSnapshotScopeSignature = self.tokenSnapshotScopeSignature(for: .codex)
        let tokenSnapshotPublicationRevision = self.tokenSnapshotPublicationRevision(for: .codex)
        let cliProxyAPIConfigurationGeneration = self.costUsageFetcher.cliProxyAPIConfigurationGeneration()
        return Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil else { return }
            let result: (
                snapshot: CostUsageTokenSnapshot,
                lastRefreshAt: Date?,
                staleSnapshotUpdatedAt: Date?)? = if let override = self._test_cachedCodexTokenSnapshotLoaderOverride
            {
                await override(now, scope.codexHomePath, historyDays)
            } else {
                await self.costUsageFetcher.loadCachedCodexTokenSnapshotResult(
                    now: now,
                    codexHomePath: scope.codexHomePath,
                    historyDays: historyDays,
                    calendar: self.settings.costUsageBucketCalendar)
                    .map {
                        (
                            snapshot: $0.snapshot,
                            lastRefreshAt: $0.lastRefreshAt,
                            staleSnapshotUpdatedAt: $0.staleSnapshotUpdatedAt)
                    }
            }
            guard let result
            else {
                return
            }
            guard self.providerPublicationRevisionIsCurrent(publicationRevision, for: .codex),
                  self.settings.providerConfigRevision(for: .codex) == providerConfigRevision,
                  self.settings.costUsageSettingsRevision == costUsageSettingsRevision,
                  self.settings.isCostUsageEffectivelyEnabled(for: .codex),
                  self.isEnabled(.codex),
                  self.tokenCostScope(for: .codex).signature == scope.signature,
                  self.settings.costUsageHistoryDays == historyDays,
                  self.tokenSnapshotScopeSignature(for: .codex) == tokenSnapshotScopeSignature,
                  self.tokenSnapshotPublicationRevision(for: .codex) == tokenSnapshotPublicationRevision,
                  self.costUsageFetcher.cliProxyAPIConfigurationGeneration() == cliProxyAPIConfigurationGeneration,
                  self.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil
            else {
                return
            }
            self.installCachedTokenSnapshot(result.snapshot, for: .codex)
            self.tokenErrors[.codex] = nil
            if result.staleSnapshotUpdatedAt != nil {
                self.startCodexCostCatchUpIfNeeded()
            }
            if let tokenFetchTTL = self.tokenFetchTTL,
               let lastRefreshAt = result.lastRefreshAt,
               now.timeIntervalSince(lastRefreshAt) >= 0,
               now.timeIntervalSince(lastRefreshAt) < tokenFetchTTL
            {
                self.lastTokenFetchAt[.codex] = lastRefreshAt
                self.lastTokenFetchScope[.codex] = tokenSnapshotScopeSignature
            }
        }
    }

    func isTokenRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider.instanceID)
    }

    func tokenCostRefreshIsActive(for provider: UsageProvider) -> Bool {
        if self.tokenRefreshInFlight.contains(provider.instanceID) {
            return true
        }
        return provider == .codex && self.codexCostCatchUpActivity?.phase == .indexing
    }

    func tokenCostScope(for provider: UsageProvider) -> (codexHomePath: String?, signature: String) {
        if provider == .vertexai {
            return (nil, "vertexai:allow-claude-fallback=\(!self.isEnabled(.claude))")
        }
        guard provider == .codex else {
            return (nil, provider.rawValue)
        }
        if self.settings.codexLocalSessionCostLedgerEnabled {
            return (nil, "codex:ambient")
        }
        let activeSource = self.settings.codexActiveSource
        switch activeSource {
        case .liveSystem:
            return (nil, "codex:ambient")
        case let .managedAccount(id):
            let homePath = self.settings.managedCodexRemoteHomePath(forActiveSource: activeSource)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let homePath, !homePath.isEmpty {
                return (homePath, "codex:managed:\(homePath)")
            }
            let unavailablePath = Self.costUsageCacheDirectory()
                .appendingPathComponent("unavailable-managed", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
                .path
            return (unavailablePath, "codex:managed:unavailable:\(id.uuidString)")
        case .profileHome:
            let homePath = self.settings.profileCodexHomePath(forActiveSource: activeSource)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let homePath, !homePath.isEmpty {
                return (homePath, "codex:profile:\(homePath)")
            }
            let unavailablePath = Self.costUsageCacheDirectory()
                .appendingPathComponent("unavailable-profile", isDirectory: true)
                .path
            return (unavailablePath, "codex:profile-unavailable")
        }
    }

    func tokenSnapshotScopeSignature(for provider: UsageProvider) -> String {
        self.tokenSnapshotScopeSignature(
            for: provider,
            historyDays: self.settings.costUsageHistoryDays,
            includeSettingsRevision: true)
    }

    func spendDashboardTokenSnapshotScopeSignature(for provider: UsageProvider) -> String {
        self.tokenSnapshotScopeSignature(
            for: provider,
            historyDays: SpendDashboardSource.scanDays,
            includeSettingsRevision: false)
    }

    func tokenSnapshotScopeSignature(
        for provider: UsageProvider,
        historyDays: Int,
        includeSettingsRevision: Bool) -> String
    {
        let scope = self.tokenCostScope(for: provider)
        var base = "\(scope.signature)|historyDays=\(historyDays)"
        if includeSettingsRevision {
            base += "|settingsRevision=\(self.settings.costUsageSettingsRevision)"
        }
        guard provider == .cursor else {
            return base
        }

        let source = self.settings.cursorCookieSource
        if source == .manual {
            let headerFingerprint = CookieHeaderNormalizer.normalize(self.settings.cursorCookieHeader)
                .map(CookieHeaderCache.credentialFingerprint) ?? "missing"
            return "\(base)|cursorCookie=manual:\(headerFingerprint)"
        }

        let credentialFingerprint = CookieHeaderCache.loadForDisplay(provider: .cursor)
            .map { CookieHeaderCache.credentialFingerprint($0.cookieHeader) } ?? "unresolved"
        return self.cursorCostScopeSignature(
            historyDays: historyDays,
            source: source,
            credentialFingerprint: credentialFingerprint,
            includeSettingsRevision: includeSettingsRevision)
    }

    func cursorCostScopeSignature(
        historyDays: Int,
        source: ProviderCookieSource,
        credentialFingerprint: String,
        includeSettingsRevision: Bool = true) -> String
    {
        let scope = self.tokenCostScope(for: .cursor)
        var signature = "\(scope.signature)|historyDays=\(historyDays)"
        if includeSettingsRevision {
            signature += "|settingsRevision=\(self.settings.costUsageSettingsRevision)"
        }
        return "\(signature)|cursorCookie=\(source.rawValue):\(credentialFingerprint)"
    }

    func tokenRefreshCanReuseCurrentSnapshot(
        provider: UsageProvider,
        now: Date,
        costScopeSignature: String) -> Bool
    {
        guard self.tokenSnapshotPublicationForCurrentProviderConfig(for: provider) != nil,
              let last = self.lastTokenFetchAt[provider.instanceID],
              self.lastTokenFetchScope[provider.instanceID] == costScopeSignature
        else {
            return false
        }
        guard let tokenFetchTTL = self.tokenFetchTTL else { return false }
        return now.timeIntervalSince(last) < tokenFetchTTL
    }

    func tokenRefreshPublicationIsCurrent(
        provider: UsageProvider,
        publicationGuard: TokenRefreshPublicationGuard,
        historyDays: Int,
        costScopeSignature: String,
        fetchedCredentialScopeFingerprint: String? = nil) -> Bool
    {
        guard self.providerPublicationRevisionIsCurrent(publicationGuard.provider, for: provider),
              self.tokenSnapshotPublicationRevision(for: provider) == publicationGuard.tokenSnapshot,
              self.settings.providerConfigRevision(for: provider) == publicationGuard.providerConfig,
              self.settings.costUsageEnabled,
              self.isEnabled(provider),
              self.settings.costUsageHistoryDays == historyDays
        else {
            return false
        }
        let currentSignature = self.tokenSnapshotScopeSignature(for: provider)
        if provider == .cursor,
           self.settings.cursorCookieSource == .auto,
           costScopeSignature.contains("|cursorCookie=auto:"),
           let fetchedCredentialScopeFingerprint
        {
            let resolvedSignature = self.cursorCostScopeSignature(
                historyDays: historyDays,
                source: .auto,
                credentialFingerprint: fetchedCredentialScopeFingerprint)
            return currentSignature == resolvedSignature
        }
        return currentSignature == costScopeSignature
    }

    func completedTokenCostScopeSignature(
        provider: UsageProvider,
        historyDays: Int,
        initialSignature: String,
        snapshot: CostUsageTokenSnapshot,
        includeSettingsRevision: Bool = true) -> String
    {
        guard provider == .cursor,
              self.settings.cursorCookieSource == .auto,
              let fingerprint = snapshot.credentialScopeFingerprint
        else { return initialSignature }
        return self.cursorCostScopeSignature(
            historyDays: historyDays,
            source: .auto,
            credentialFingerprint: fingerprint,
            includeSettingsRevision: includeSettingsRevision)
    }

    func tokenSnapshot(
        fromProviderSnapshot snapshot: UsageSnapshot?,
        provider: UsageProvider,
        historyDays: Int? = nil)
        -> CostUsageTokenSnapshot?
    {
        let windowDays = historyDays ?? self.settings.costUsageHistoryDays
        // Provider-specific by design: snapshot-backed spend sources own their live billing
        // projection. Grok contributes local session tokens only; xAI contributes Management API
        // daily spend only. Neither converts a quota or prepaid balance into dollars.
        switch provider {
        case .openai:
            return snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot()
        case .mistral:
            return snapshot?.mistralUsage?.toCostUsageTokenSnapshot(historyDays: windowDays)
        case .opencodego:
            // Web-only source mode and machines with no readable local database leave
            // `opencodegoUsage.daily` empty; a non-nil-but-dataless projection would still
            // surface a Cost row whose history submenu has nothing to render.
            return snapshot?.opencodegoUsage.flatMap { usage in
                usage.daily.isEmpty ? nil : usage
                    .toCostUsageTokenSnapshot(historyDays: windowDays)
            }
        case .openrouter:
            return snapshot?.costUsage
        case .xai:
            return snapshot.flatMap { XAICostUsageMapping.tokenSnapshot(from: $0, historyDays: windowDays) }
        case .grok:
            return GrokLocalSessionScanner.summarize(lookbackDays: windowDays)
                .toCostUsageTokenSnapshot(historyDays: windowDays)
        default:
            return nil
        }
    }

    nonisolated static func tokenCostRequiresProviderSnapshot(_ provider: UsageProvider) -> Bool {
        // Provider-specific by design: these providers project live usage snapshots into the
        // shared spend catalog instead of running the local CostUsageFetcher JSONL pipeline.
        switch provider {
        case .grok, .mistral, .openai, .opencodego, .openrouter, .xai:
            true
        default:
            false
        }
    }

    nonisolated static func costUsageCacheDirectory(
        fileManager: FileManager = .default) -> URL
    {
        CostUsageCacheLocations.directories(fileManager: fileManager)[0]
    }

    func clearCostUsageCache(
        clearDirectories: (@Sendable () async -> (cleared: Int, errorMessage: String?))? = nil,
        fileManager: FileManager = .default) async -> String?
    {
        guard !self.costUsageCacheClearInProgress else { return nil }
        self.costUsageCacheClearInProgress = true
        defer { self.costUsageCacheClearInProgress = false }

        let collectorTask = self.stopCLIProxyAPIUsageCollector()
        await collectorTask?.value
        defer {
            if collectorTask != nil {
                self.startCLIProxyAPIUsageCollector()
            }
        }

        await self.drainTokenRefreshesForCostCacheClear()
        self.cancelCodexCostCatchUp()
        self.cancelSpendDashboardCodexCostCatchUp()

        let cacheDirectories = CostUsageCacheLocations.directories(fileManager: fileManager)
        let cliProxyAPIStateRoot = cacheDirectories[1].deletingLastPathComponent()
        let clearResult: (didClear: Bool, errorMessage: String?)
        if let clearDirectories {
            let result = await clearDirectories()
            clearResult = (result.errorMessage == nil || result.cleared > 0, result.errorMessage)
        } else {
            let result = await Task.detached(priority: .utility) {
                CostUsageCacheLocations.clearAllCostUsageCaches(
                    in: cacheDirectories,
                    stateRoot: cliProxyAPIStateRoot)
            }.value
            clearResult = (result.errorDescription == nil || result.cleared > 0, result.errorDescription)
        }

        guard clearResult.didClear else { return clearResult.errorMessage }

        self.clearTokenSnapshots()
        self.spendDashboardCodexCostCatchUpRevision &+= 1
        self.tokenErrors.removeAll()
        self.lastTokenFetchAt.removeAll()
        self.lastTokenFetchScope.removeAll()
        self.tokenFailureGates[.codex]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        return clearResult.errorMessage
    }

    /// Fast failures may retry on the next scheduled pass instead of waiting out the fetch
    /// TTL; timed-out scans keep the TTL so a slow corpus cannot thrash back-to-back rescans.
    nonisolated static func tokenFetchFailureAllowsEarlyRetry(_ error: Error) -> Bool {
        if case CostUsageError.timedOut = error {
            return false
        }
        return true
    }

    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.noDataMessage()
    }
}
