import CodexBarCore
import Foundation

struct CurrentProviderConfigTokenSnapshot: Sendable, Equatable {
    let snapshot: CostUsageTokenSnapshot
    let publicationRevision: UInt64
    let accounting: PiSnapshotAccounting?
}

struct CurrentProviderConfigTokenPublication: Sendable, Equatable {
    let snapshot: CostUsageTokenSnapshot?
    let publicationRevision: UInt64
    let accounting: PiSnapshotAccounting?
}

struct TokenSnapshotPublication: Sendable, Equatable {
    let snapshot: CostUsageTokenSnapshot?
    let publicationRevision: UInt64
    let providerConfigRevision: UInt64
    let scopeSignature: String
    let accounting: PiSnapshotAccounting?
}

extension UsageStore {
    func logTokenUsageSuccess(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        historyDays: Int,
        startedAt: Date)
    {
        let durationText = String(format: "%.2f", Date().timeIntervalSince(startedAt))
        let sessionCost = snapshot.sessionCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let monthCost = snapshot.last30DaysCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let message =
            "cost usage success provider=\(provider.rawValue) " +
            "duration=\(durationText)s " +
            "today=\(sessionCost) " +
            "historyDays=\(historyDays) windowCost=\(monthCost)"
        self.tokenCostLogger.info(message)
    }

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

    /// Provider-specific by design: Pi, Claude, and unscoped Codex share the Pi history scope lifecycle.
    private func usesPiHistoryScope(_ provider: UsageProvider) -> Bool {
        provider == .pi || provider == .claude ||
            (provider == .codex && self.tokenCostScope(for: provider).codexHomePath == nil)
    }

    func tokenAccountingScopeIsCurrent(_ accounting: PiSnapshotAccounting?, for provider: UsageProvider) -> Bool {
        guard self.usesPiHistoryScope(provider), let scope = accounting?.scope else { return true }
        guard let current = self.piHistoryScopeFingerprint else { return true }
        return scope == current
    }

    func refreshPiHistoryScope(for provider: UsageProvider) async -> Bool {
        guard self.usesPiHistoryScope(provider) else { return true }
        // Synthetic snapshot/cache overrides own their source and must not resolve real processes.
        if self._test_tokenUsageSnapshotLoaderOverride != nil ||
            self._test_tokenUsageRefreshOverride != nil ||
            self._test_cachedCodexTokenSnapshotLoaderOverride != nil
        {
            return true
        }
        let fingerprint: String
        do {
            fingerprint = try await CostUsageFetcher.piRootScope(environment: self.environmentBase)
        } catch {
            self.tokenErrors[provider.instanceID] = "Pi history configuration is unavailable."
            return false
        }
        guard self.piHistoryScopeFingerprint != fingerprint else { return true }
        self.piHistoryScopeFingerprint = fingerprint
        self.piHistoryScopeGeneration &+= 1
        // Provider-specific by design: a Pi scope change invalidates every publication that can consume that history.
        for scopedProvider in [UsageProvider.pi, .claude, .codex] where self.usesPiHistoryScope(scopedProvider) {
            self.clearTokenSnapshot(for: scopedProvider)
            self.clearSpendDashboardTokenSnapshot(for: scopedProvider)
            self.lastTokenFetchAt.removeValue(forKey: scopedProvider.instanceID)
            self.lastTokenFetchScope.removeValue(forKey: scopedProvider.instanceID)
        }
        self.synchronizeSharedSpendDashboardAfterTokenPublication(for: .pi)
        return true
    }

    /// Reports used by the combined dashboard can describe Pi as a separate
    /// source. The fetcher still supports inclusive standalone reads; this
    /// helper keeps the existing ownership label for scope invalidation.
    func shouldIncludePiSessionsInTokenSnapshot(for provider: UsageProvider) -> Bool {
        guard provider == .claude || provider == .codex else { return true }
        let piIsCostSource = self.settings.isProviderEnabledCached(
            provider: .pi,
            metadataByProvider: self.providerMetadata) &&
            self.settings.isCostUsageEffectivelyEnabled(for: .pi)
        return !piIsCostSource
    }

    func piRowsScopeSignature(for provider: UsageProvider) -> String? {
        guard provider == .claude || provider == .codex else { return nil }
        return self.shouldIncludePiSessionsInTokenSnapshot(for: provider) ? "fallback" : "owned"
    }

    func loadTokenUsageSnapshot(
        provider: UsageProvider,
        force: Bool,
        now: Date,
        codexHomePath: String?,
        historyDays: Int,
        cursorCookieHeaderOverride: String? = nil,
        includePiSessions: Bool = true) async throws -> CostUsageTokenResult
    {
        if let override = self._test_tokenUsageSnapshotLoaderOverride {
            let snapshot = try await override(provider, force, now, codexHomePath, historyDays)
            return CostUsageTokenResult(snapshot: snapshot)
        }

        let fetcher = self.costUsageFetcher
        let timeoutSeconds = self.tokenFetchTimeout
        let effectiveIncludePiSessions = includePiSessions
        // Provider-specific by design: the Codex ledger owns pricing refresh while Bedrock resolves AWS environment.
        let allowPricingRefresh = provider != .codex || !self.settings.codexLocalSessionCostLedgerEnabled
        let environment = provider == .bedrock
            ? ProviderRegistry.makeEnvironment(
                base: self.environmentBase,
                provider: provider,
                settings: self.settings,
                tokenOverride: nil)
            : self.environmentBase
        let scopedCodexHomePath = codexHomePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Provider-specific by design: only Pi-owned, Claude-inclusive, or unscoped Codex scans consume Pi roots.
        let shouldDiscoverPiSessionProcessContexts = provider == .pi ||
            (effectiveIncludePiSessions &&
                (provider == .claude || (provider == .codex && scopedCodexHomePath?.isEmpty != false)))
        let piSessionProcessContexts: [PiSessionProcessContext] = if shouldDiscoverPiSessionProcessContexts {
            await LocalAgentSessionScanner().piSessionProcessContexts(environment: environment)
        } else {
            []
        }
        return try await withThrowingTaskGroup(of: CostUsageTokenResult.self) { group in
            group.addTask(priority: .utility) {
                try await fetcher.loadTokenResult(
                    provider: provider,
                    environment: environment,
                    now: now,
                    forceRefresh: force,
                    allowVertexClaudeFallback: !self.isEnabled(.claude),
                    codexHomePath: codexHomePath,
                    historyDays: historyDays,
                    cursorCookieHeaderOverride: cursorCookieHeaderOverride,
                    allowPricingRefresh: allowPricingRefresh,
                    includePiSessions: effectiveIncludePiSessions,
                    piSessionProcessContexts: piSessionProcessContexts,
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
            publicationRevision: publication.publicationRevision,
            accounting: publication.accounting)
    }

    func tokenSnapshotPublicationForCurrentProviderConfig(
        for provider: UsageProvider) -> CurrentProviderConfigTokenPublication?
    {
        guard let publication = self.tokenSnapshotPublications[provider.instanceID],
              publication.providerConfigRevision == self.settings.providerConfigRevision(for: provider),
              publication.scopeSignature == self.tokenSnapshotScopeSignature(for: provider)
        else { return nil }
        return CurrentProviderConfigTokenPublication(
            snapshot: publication.snapshot,
            publicationRevision: publication.publicationRevision,
            accounting: publication.accounting)
    }

    func tokenSnapshotPublicationRevision(for provider: UsageProvider) -> UInt64 {
        self.tokenSnapshotPublicationRevisions[provider.instanceID] ?? 0
    }

    enum TokenSnapshotError: LocalizedError {
        case historyUnavailable

        var errorDescription: String? {
            "Local token history is unavailable or incomplete."
        }
    }

    func retainsEstablishedTokenHistory(_ snapshot: CostUsageTokenSnapshot, for provider: UsageProvider) -> Bool {
        // A bounded Codex refresh can succeed with partial rows while catch-up remains pending.
        // Account and history-window changes fail the current-publication lookup below.
        // Provider-specific by design: only Codex retains established history during bounded catch-up.
        if provider == .codex,
           !snapshot.historyCoverageIsEstablished,
           self.tokenSnapshotPublicationForCurrentProviderConfig(for: provider)?
               .snapshot?.historyCoverageIsEstablished == true
        {
            return true
        }
        return false
    }

    func publishTokenSnapshot(
        _ snapshot: CostUsageTokenSnapshot,
        for provider: UsageProvider,
        accounting: PiSnapshotAccounting? = nil)
    {
        if self.retainsEstablishedTokenHistory(snapshot, for: provider) { return }
        self.tokenSnapshots[provider.instanceID] = snapshot
        self.publishTokenSnapshotState(snapshot, for: provider, accounting: accounting)
    }

    func publishConfirmedEmptyTokenSnapshot(
        for provider: UsageProvider,
        accounting: PiSnapshotAccounting? = nil)
    {
        self.tokenSnapshots.removeValue(forKey: provider.instanceID)
        self.publishTokenSnapshotState(nil, for: provider, accounting: accounting)
    }

    private func publishTokenSnapshotState(
        _ snapshot: CostUsageTokenSnapshot?,
        for provider: UsageProvider,
        accounting: PiSnapshotAccounting?)
    {
        self.tokenSnapshotPublicationRevisions[provider.instanceID, default: 0] &+= 1
        self.tokenSnapshotPublications[provider.instanceID] = TokenSnapshotPublication(
            snapshot: snapshot,
            publicationRevision: self.tokenSnapshotPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            scopeSignature: self.tokenSnapshotScopeSignature(for: provider),
            accounting: accounting)
        self.synchronizeSharedSpendDashboardAfterTokenPublication(for: provider)
    }

    func installCachedTokenSnapshot(
        _ snapshot: CostUsageTokenSnapshot,
        for provider: UsageProvider,
        accounting: PiSnapshotAccounting? = nil)
    {
        self.tokenSnapshots[provider.instanceID] = snapshot
        self.tokenSnapshotPublications[provider.instanceID] = TokenSnapshotPublication(
            snapshot: snapshot,
            publicationRevision: self.tokenSnapshotPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            scopeSignature: self.tokenSnapshotScopeSignature(for: provider),
            accounting: accounting)
    }

    func clearTokenSnapshot(for provider: UsageProvider) {
        self.tokenSnapshots.removeValue(forKey: provider.instanceID)
        self.tokenSnapshotPublications.removeValue(forKey: provider.instanceID)
    }

    func clearTokenSnapshots() {
        self.tokenSnapshots.removeAll()
        self.tokenSnapshotPublications.removeAll()
        self.spendDashboardTokenPublications.removeAll()
        self.spendDashboardTokenPublicationRevisions.removeAll()
        self.spendDashboardTokenIncorporatedTriggers.removeAll()
        self.spendDashboardTokenFailedTriggers.removeAll()
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
        let includePiSessions = self.shouldIncludePiSessionsInTokenSnapshot(for: .codex)
        return Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.refreshPiHistoryScope(for: .codex) else { return }
            guard self.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil else { return }
            let result: (
                snapshot: CostUsageTokenSnapshot,
                lastRefreshAt: Date?,
                staleSnapshotUpdatedAt: Date?,
                accounting: PiSnapshotAccounting?)? = if let override =
                self._test_cachedCodexTokenSnapshotLoaderOverride
            {
                await override(now, scope.codexHomePath, historyDays).map {
                    ($0.snapshot, $0.lastRefreshAt, $0.staleSnapshotUpdatedAt, nil)
                }
            } else {
                await self.costUsageFetcher.loadCachedCodexTokenSnapshotResult(
                    now: now,
                    codexHomePath: scope.codexHomePath,
                    historyDays: historyDays,
                    includePiSessions: includePiSessions,
                    calendar: self.settings.costUsageBucketCalendar,
                    environment: self.environmentBase)
                    .map {
                        (
                            snapshot: $0.snapshot,
                            lastRefreshAt: $0.lastRefreshAt,
                            staleSnapshotUpdatedAt: $0.staleSnapshotUpdatedAt,
                            accounting: $0.accounting)
                    }
            }
            guard let result
            else {
                return
            }
            // Provider-specific by design: cache hydration publishes only after all fixed Codex scope checks pass.
            guard await self.refreshPiHistoryScope(for: .codex),
                  self.providerPublicationRevisionIsCurrent(publicationRevision, for: .codex),
                  self.tokenAccountingScopeIsCurrent(result.accounting, for: .codex),
                  self.settings.providerConfigRevision(for: .codex) == providerConfigRevision,
                  self.settings.costUsageSettingsRevision == costUsageSettingsRevision,
                  self.settings.isCostUsageEffectivelyEnabled(for: .codex),
                  self.isEnabled(.codex),
                  self.tokenCostScope(for: .codex).signature == scope.signature,
                  self.settings.costUsageHistoryDays == historyDays,
                  self.tokenSnapshotScopeSignature(for: .codex) == tokenSnapshotScopeSignature,
                  self.tokenSnapshotPublicationRevision(for: .codex) == tokenSnapshotPublicationRevision,
                  self.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil
            else {
                return
            }
            self.installCachedTokenSnapshot(result.snapshot, for: .codex, accounting: result.accounting)
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
        if let piRowsScope = self.piRowsScopeSignature(for: provider) {
            base += "|piRows=\(piRowsScope)"
        }
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
        publicationRevision: ProviderPublicationRevision,
        providerConfigRevision: UInt64,
        historyDays: Int,
        costScopeSignature: String,
        fetchedCredentialScopeFingerprint: String? = nil) -> Bool
    {
        guard self.providerPublicationRevisionIsCurrent(publicationRevision, for: provider),
              self.settings.providerConfigRevision(for: provider) == providerConfigRevision,
              self.settings.isCostUsageEffectivelyEnabled(for: provider),
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
            return self.grokLocalTokenSnapshot(from: snapshot, historyDays: windowDays)
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

    func regularTokenSnapshotIsConfirmedEmpty(
        _ snapshot: CostUsageTokenSnapshot,
        for provider: UsageProvider) throws -> Bool
    {
        guard snapshot.daily.isEmpty, snapshot.meteredCostUSD == nil else { return false }
        if snapshot.historyCoverageIsEstablished { return true }
        guard self.retainsEstablishedTokenHistory(snapshot, for: provider) else {
            throw TokenSnapshotError.historyUnavailable
        }
        return false
    }

    struct TokenUsageRefreshContext {
        let provider: UsageProvider
        let now: Date
        let historyDays: Int
        let costScopeSignature: String
        let publicationRevision: ProviderPublicationRevision
        let providerConfigRevision: UInt64
        let startedAt: Date
    }

    func commitTokenUsageResult(
        _ result: CostUsageTokenResult,
        context: TokenUsageRefreshContext) throws
    {
        let snapshot = result.snapshot
        try Task.checkCancellation()
        guard self.tokenAccountingScopeIsCurrent(result.accounting, for: context.provider) else {
            self.clearTokenFetchMetadataIfMatching(
                provider: context.provider,
                attemptedAt: context.now,
                costScopeSignature: context.costScopeSignature)
            self.requestTokenRefreshAfterStaleCompletion(for: context.provider)
            return
        }
        let completedCostScopeSignature = self.completedTokenCostScopeSignature(
            provider: context.provider,
            historyDays: context.historyDays,
            initialSignature: context.costScopeSignature,
            snapshot: snapshot)
        guard self.tokenRefreshPublicationIsCurrent(
            provider: context.provider,
            publicationRevision: context.publicationRevision,
            providerConfigRevision: context.providerConfigRevision,
            historyDays: context.historyDays,
            costScopeSignature: context.costScopeSignature,
            fetchedCredentialScopeFingerprint: snapshot.credentialScopeFingerprint)
        else {
            self.clearTokenFetchMetadataIfMatching(
                provider: context.provider,
                attemptedAt: context.now,
                costScopeSignature: context.costScopeSignature)
            self.requestTokenRefreshAfterStaleCompletion(for: context.provider)
            return
        }
        self.lastTokenFetchScope[context.provider.instanceID] = completedCostScopeSignature
        self.startCodexCostCatchUpIfNeeded(afterRefreshing: context.provider)

        if try self.regularTokenSnapshotIsConfirmedEmpty(snapshot, for: context.provider) {
            self.publishConfirmedEmptyTokenSnapshot(for: context.provider, accounting: result.accounting)
            self.tokenErrors[context.provider.instanceID] = Self.tokenCostNoDataMessage(for: context.provider)
            self.tokenFailureGates[context.provider.instanceID]?.recordSuccess()
            return
        }
        self.logTokenUsageSuccess(
            provider: context.provider,
            snapshot: snapshot,
            historyDays: context.historyDays,
            startedAt: context.startedAt)
        self.publishTokenSnapshot(snapshot, for: context.provider, accounting: result.accounting)
        self.tokenErrors[context.provider.instanceID] = nil
        self.tokenFailureGates[context.provider.instanceID]?.recordSuccess()
        self.persistWidgetSnapshot(reason: "token-usage")
    }

    func resetTokenUsageState(for provider: UsageProvider) {
        // Provider-specific by design: resetting Codex token state also cancels its two ledger catch-up workflows.
        if provider == .codex {
            self.cancelCodexCostCatchUp()
            self.cancelSpendDashboardCodexCostCatchUp()
        }
        self.clearTokenSnapshot(for: provider)
        self.clearSpendDashboardTokenSnapshot(for: provider)
        self.tokenErrors[provider.instanceID] = nil
        self.tokenFailureGates[provider.instanceID]?.reset()
        self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
        self.lastSpendDashboardTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastSpendDashboardTokenFetchScope.removeValue(forKey: provider.instanceID)
    }

    func clearTokenFetchMetadataIfMatching(
        provider: UsageProvider,
        attemptedAt: Date,
        costScopeSignature: String)
    {
        guard self.lastTokenFetchAt[provider.instanceID] == attemptedAt,
              self.lastTokenFetchScope[provider.instanceID] == costScopeSignature
        else {
            return
        }
        self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
    }

    /// Fast failures may retry on the next scheduled pass instead of waiting out the fetch
    /// TTL; timed-out scans keep the TTL so a slow corpus cannot thrash back-to-back rescans.
    nonisolated static func tokenFetchFailureAllowsEarlyRetry(_ error: Error) -> Bool {
        if case CostUsageError.timedOut = error {
            return false
        }
        return true
    }

    func tokenCostIsAccountAgnostic(for provider: UsageProvider) -> Bool {
        // Provider-specific by design: only Codex's explicit ambient scope spans local accounts.
        provider == .codex && self.tokenCostScope(for: provider).signature == "codex:ambient"
    }
}
