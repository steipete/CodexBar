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

struct TokenSnapshotPublication: Sendable, Equatable {
    let snapshot: CostUsageTokenSnapshot?
    let publicationRevision: UInt64
    let providerConfigRevision: UInt64
    let historyDays: Int
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
        self.tokenSnapshots[provider.instanceID]
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
              publication.providerConfigRevision == self.settings.providerConfigRevision(for: provider)
        else { return nil }
        let requiredHistoryDays = self.settings.effectiveCostUsageHistoryDays
        guard publication.historyDays >= requiredHistoryDays,
              publication.scopeSignature == self.tokenSnapshotScopeSignature(
                  for: provider,
                  historyDays: publication.historyDays)
        else { return nil }
        return CurrentProviderConfigTokenPublication(
            snapshot: publication.snapshot,
            publicationRevision: publication.publicationRevision)
    }

    func tokenSnapshotPublicationRevision(for provider: UsageProvider) -> UInt64 {
        self.tokenSnapshotPublicationRevisions[provider.instanceID] ?? 0
    }

    func publishTokenSnapshot(_ snapshot: CostUsageTokenSnapshot, for provider: UsageProvider) {
        self.tokenSnapshots[provider.instanceID] = snapshot
        self.publishTokenSnapshotState(snapshot, for: provider)
    }

    func publishConfirmedEmptyTokenSnapshot(for provider: UsageProvider) {
        self.tokenSnapshots.removeValue(forKey: provider.instanceID)
        self.publishTokenSnapshotState(nil, for: provider)
    }

    private func publishTokenSnapshotState(_ snapshot: CostUsageTokenSnapshot?, for provider: UsageProvider) {
        let historyDays = self.settings.effectiveCostUsageHistoryDays
        self.tokenSnapshotPublicationRevisions[provider.instanceID, default: 0] &+= 1
        self.tokenSnapshotPublications[provider.instanceID] = TokenSnapshotPublication(
            snapshot: snapshot,
            publicationRevision: self.tokenSnapshotPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            historyDays: historyDays,
            scopeSignature: self.tokenSnapshotScopeSignature(for: provider, historyDays: historyDays))
    }

    func installCachedTokenSnapshot(_ snapshot: CostUsageTokenSnapshot, for provider: UsageProvider) {
        let historyDays = self.settings.effectiveCostUsageHistoryDays
        self.tokenSnapshots[provider.instanceID] = snapshot
        self.tokenSnapshotPublications[provider.instanceID] = TokenSnapshotPublication(
            snapshot: snapshot,
            publicationRevision: self.tokenSnapshotPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            historyDays: historyDays,
            scopeSignature: self.tokenSnapshotScopeSignature(for: provider, historyDays: historyDays))
    }

    func clearTokenSnapshot(for provider: UsageProvider) {
        self.tokenSnapshots.removeValue(forKey: provider.instanceID)
        self.tokenSnapshotPublications.removeValue(forKey: provider.instanceID)
    }

    func clearTokenSnapshots() {
        self.tokenSnapshots.removeAll()
        self.tokenSnapshotPublications.removeAll()
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
        let historyDays = self.settings.effectiveCostUsageHistoryDays
        let publicationRevision = self.providerPublicationRevision(for: .codex)
        let providerConfigRevision = self.settings.providerConfigRevision(for: .codex)
        let costUsageSettingsRevision = self.settings.costUsageSettingsRevision
        let tokenSnapshotScopeSignature = self.tokenSnapshotScopeSignature(for: .codex)
        let tokenSnapshotPublicationRevision = self.tokenSnapshotPublicationRevision(for: .codex)
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
                    historyDays: historyDays)
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
                  self.settings.effectiveCostUsageHistoryDays == historyDays,
                  self.tokenSnapshotScopeSignature(for: .codex) == tokenSnapshotScopeSignature,
                  self.tokenSnapshotPublicationRevision(for: .codex) == tokenSnapshotPublicationRevision,
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

    func tokenSnapshotScopeSignature(
        for provider: UsageProvider,
        historyDays requestedHistoryDays: Int? = nil) -> String
    {
        let scope = self.tokenCostScope(for: provider)
        let historyDays = max(1, min(365, requestedHistoryDays ?? self.settings.effectiveCostUsageHistoryDays))
        let base = "\(scope.signature)|historyDays=\(historyDays)" +
            "|settingsRevision=\(self.settings.costUsageSettingsRevision)"
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
            credentialFingerprint: credentialFingerprint)
    }

    func cursorCostScopeSignature(
        historyDays: Int,
        source: ProviderCookieSource,
        credentialFingerprint: String) -> String
    {
        let scope = self.tokenCostScope(for: .cursor)
        return "\(scope.signature)|historyDays=\(historyDays)" +
            "|settingsRevision=\(self.settings.costUsageSettingsRevision)" +
            "|cursorCookie=\(source.rawValue):\(credentialFingerprint)"
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
        publicationRevision: ProviderPublicationRevision,
        providerConfigRevision: UInt64,
        historyDays: Int,
        costScopeSignature: String,
        fetchedCredentialScopeFingerprint: String? = nil) -> Bool
    {
        guard self.providerPublicationRevisionIsCurrent(publicationRevision, for: provider),
              self.settings.providerConfigRevision(for: provider) == providerConfigRevision,
              self.settings.costUsageEnabled,
              self.isEnabled(provider),
              self.settings.effectiveCostUsageHistoryDays == historyDays
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
        snapshot: CostUsageTokenSnapshot) -> String
    {
        guard provider == .cursor,
              self.settings.cursorCookieSource == .auto,
              let fingerprint = snapshot.credentialScopeFingerprint
        else { return initialSignature }
        return self.cursorCostScopeSignature(
            historyDays: historyDays,
            source: .auto,
            credentialFingerprint: fingerprint)
    }

    func tokenSnapshot(
        fromProviderSnapshot snapshot: UsageSnapshot?,
        provider: UsageProvider)
        -> CostUsageTokenSnapshot?
    {
        switch provider {
        case .openai:
            snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot()
        case .openrouter:
            snapshot?.openRouterActivityUsage?.toCostUsageTokenSnapshot()
        case .mistral:
            snapshot?.mistralUsage?.toCostUsageTokenSnapshot(historyDays: self.settings.effectiveCostUsageHistoryDays)
        case .opencodego:
            // Web-only source mode and machines with no readable local database leave
            // `opencodegoUsage.daily` empty; a non-nil-but-dataless projection would still
            // surface a Cost row whose history submenu has nothing to render.
            snapshot?.opencodegoUsage.flatMap { usage in
                usage.daily.isEmpty ? nil : usage
                    .toCostUsageTokenSnapshot(historyDays: self.settings.effectiveCostUsageHistoryDays)
            }
        default:
            nil
        }
    }

    nonisolated static func tokenCostRequiresProviderSnapshot(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .mistral, .openai, .openrouter, .opencodego:
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

        self.clearTokenSnapshots()
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

    func preservingOpenRouterActivityIfCurrent(
        _ snapshot: UsageSnapshot,
        previous: UsageSnapshot?) -> UsageSnapshot
    {
        guard snapshot.openRouterActivityUsage == nil,
              self.tokenSnapshotPublicationForCurrentProviderConfig(for: .openrouter)?.snapshot != nil,
              let activity = previous?.openRouterActivityUsage
        else { return snapshot }
        return snapshot.withOpenRouterActivityUsage(activity)
    }
}
