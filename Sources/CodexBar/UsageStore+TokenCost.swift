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
            self.tokenFetchFailureCooldowns.removeValue(forKey: provider.instanceID)
            self.clearTokenSnapshot(for: provider)
            self.tokenErrors[provider.instanceID] = "Cursor cost requires a non-empty Manual cookie header."
            self.tokenFailureGates[provider.instanceID]?.reset()
            return .reject
        }
        return .proceed(header)
    }

    /// Provider-specific by design: Pi, Claude, and unscoped Codex share the Pi history scope lifecycle.
    private func usesPiHistoryScope(_ provider: UsageProvider) -> Bool {
        provider == .pi || (self.shouldIncludePiSessionsInTokenSnapshot(for: provider) &&
            (provider == .claude ||
                (provider == .codex && self.tokenCostScope(for: provider).codexHomePath == nil)))
    }

    func tokenAccountingScopeIsCurrent(_ accounting: PiSnapshotAccounting?, for provider: UsageProvider) -> Bool {
        guard self.usesPiHistoryScope(provider), let scope = accounting?.scope else { return true }
        guard let current = self.piHistoryScopeFingerprint else { return true }
        return scope == current
    }

    func refreshPiHistoryScope(for provider: UsageProvider) async -> Bool {
        guard self.usesPiHistoryScope(provider) else { return true }
        // Synthetic snapshot/cache overrides own their source and must not resolve real processes.
        if self._test_piHistoryScopeResolver == nil,
           self._test_tokenUsageResultLoaderOverride != nil ||
           self._test_tokenUsageSnapshotLoaderOverride != nil ||
           self._test_tokenUsageRefreshOverride != nil ||
           self._test_cachedCodexTokenSnapshotLoaderOverride != nil
        {
            return true
        }
        if let pending = self.piHistoryScopeRefreshTask { return await pending.value }
        // One resolver publishes the shared scope; older concurrent completions cannot overwrite it.
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.piHistoryScopeRefreshTask = nil }
            let fingerprint: String
            do {
                if let resolver = self._test_piHistoryScopeResolver {
                    fingerprint = try await resolver(self.environmentBase)
                } else {
                    fingerprint = try await CostUsageFetcher.piRootScope(environment: self.environmentBase)
                }
            } catch {
                self.tokenErrors[provider.instanceID] = "Pi history configuration is unavailable."
                return false
            }
            guard self.piHistoryScopeFingerprint != fingerprint else { return true }
            self.piHistoryScopeFingerprint = fingerprint
            self.piHistoryScopeGeneration &+= 1
            // Provider-specific by design: invalidate only consumers that include Pi history.
            for scopedProvider in [UsageProvider.pi, .claude, .codex] where self.usesPiHistoryScope(scopedProvider) {
                self.clearTokenSnapshot(for: scopedProvider)
                self.clearSpendDashboardTokenSnapshot(for: scopedProvider)
                self.lastTokenFetchAt.removeValue(forKey: scopedProvider.instanceID)
                self.lastTokenFetchScope.removeValue(forKey: scopedProvider.instanceID)
            }
            self.synchronizeSharedSpendDashboardAfterTokenPublication(for: .pi)
            return true
        }
        self.piHistoryScopeRefreshTask = task
        return await task.value
    }

    /// Reports used by the combined dashboard can describe Pi as a separate
    /// source. The fetcher still supports inclusive standalone reads; this
    /// helper keeps the existing ownership label for scope invalidation.
    func shouldIncludePiSessionsInTokenSnapshot(for provider: UsageProvider) -> Bool {
        guard provider == .claude || provider == .codex else { return true }
        if provider == .codex, self.tokenCostScope(for: provider).codexHomePath != nil { return false }
        let piIsCostSource = self.settings.isProviderEnabledCached(
            provider: .pi,
            metadataByProvider: self.providerMetadata) &&
            self.settings.isCostUsageEffectivelyEnabled(for: .pi)
        return !piIsCostSource
    }

    func piRowsScopeSignature(for provider: UsageProvider) -> String? {
        guard provider == .claude ||
            (provider == .codex && self.tokenCostScope(for: provider).codexHomePath == nil)
        else { return nil }
        return self.shouldIncludePiSessionsInTokenSnapshot(for: provider) ? "fallback" : "owned"
    }

    func loadTokenUsageSnapshot(
        provider: UsageProvider,
        force: Bool,
        now: Date,
        codexHomePath: String?,
        historyDays: Int,
        cursorCookieHeaderOverride: String? = nil,
        includePiSessions: Bool = true,
        reportContext: CostUsageReportContext = .regular) async throws -> CostUsageTokenResult
    {
        if let override = self._test_tokenUsageResultLoaderOverride {
            return try await override(provider, force, now, codexHomePath, historyDays, includePiSessions)
        }
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
                    calendar: self.settings.costUsageBucketCalendar,
                    reportContext: reportContext)
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
        // Provider-specific by design: bounded Codex and partial Antigravity scans retain complete same-scope history.
        if (provider == .codex && !snapshot.historyCoverageIsEstablished)
            || (provider == .antigravity && snapshot.historyScanIsPartial),
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
        self.publishTokenSnapshotState(snapshot, for: provider, accounting: accounting)
    }

    func publishConfirmedEmptyTokenSnapshot(
        for provider: UsageProvider,
        accounting: PiSnapshotAccounting? = nil)
    {
        self.publishTokenSnapshotState(nil, for: provider, accounting: accounting)
    }

    private func publishTokenSnapshotState(
        _ snapshot: CostUsageTokenSnapshot?,
        for provider: UsageProvider,
        accounting: PiSnapshotAccounting?)
    {
        self.tokenSnapshotPublicationRevisions[provider.instanceID, default: 0] &+= 1
        self.installCachedTokenSnapshot(snapshot, for: provider, accounting: accounting)
        self.synchronizeSharedSpendDashboardAfterTokenPublication(for: provider)
    }

    /// The menu card projects quota weeks synchronously while it builds, so the per-slice pass runs
    /// off the main actor when possible; a card arriving first can still build it synchronously.
    private func warmQuotaProjection(for snapshot: CostUsageTokenSnapshot?) {
        guard let snapshot, !snapshot.quotaSlices.isEmpty || !snapshot.hourly.isEmpty else { return }
        let calendar = self.settings.costUsageBucketCalendar
        Task.detached(priority: .utility) {
            snapshot.warmQuotaProjection(calendar: calendar)
        }
    }

    func installCachedTokenSnapshot(
        _ snapshot: CostUsageTokenSnapshot?,
        for provider: UsageProvider,
        accounting: PiSnapshotAccounting? = nil)
    {
        self.tokenSnapshotPublications[provider.instanceID] = TokenSnapshotPublication(
            snapshot: snapshot?.reporting(self.settings.costReportingPeriod),
            publicationRevision: self.tokenSnapshotPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            scopeSignature: self.tokenSnapshotScopeSignature(for: provider),
            accounting: accounting)
        self.warmQuotaProjection(for: snapshot)
    }

    func clearTokenSnapshot(for provider: UsageProvider) {
        self.tokenSnapshotPublications.removeValue(forKey: provider.instanceID)
    }

    func clearTokenSnapshots() {
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

        return Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.refreshPiHistoryScope(for: .codex) else { return }
            let scope = self.tokenCostScope(for: .codex)
            let historyDays = self.settings.costReportingPeriod.days(
                now: now,
                calendar: self.settings.costUsageBucketCalendar)
            let publicationRevision = self.providerPublicationRevision(for: .codex)
            let providerConfigRevision = self.settings.providerConfigRevision(for: .codex)
            let costUsageSettingsRevision = self.settings.costUsageSettingsRevision
            let tokenSnapshotScopeSignature = self.tokenSnapshotScopeSignature(for: .codex)
            let tokenSnapshotPublicationRevision = self.tokenSnapshotPublicationRevision(for: .codex)
            let includePiSessions = self.shouldIncludePiSessionsInTokenSnapshot(for: .codex)
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
        if self.usesPiHistoryScope(provider) {
            base += "|piHistoryGeneration=\(self.piHistoryScopeGeneration)"
        }
        if let piRowsScope = self.piRowsScopeSignature(for: provider) {
            base += "|piRows=\(piRowsScope)"
        }
        if includeSettingsRevision {
            base += "|settingsRevision=\(self.settings.costUsageSettingsRevision)|"
                + self.settings.costReportingPeriod.identity(
                    now: Date(),
                    calendar: self.settings.costUsageBucketCalendar)
        }
        guard provider == .cursor else {
            return base
        }

        let source = self.settings.cursorCookieSource
        let credentialFingerprint = if source == .manual {
            CookieHeaderNormalizer.normalize(self.settings.cursorCookieHeader)
                .map(CookieHeaderCache.credentialFingerprint) ?? "missing"
        } else {
            self.cursorCostCredentialFingerprintForDisplay() ?? "unresolved"
        }
        return "\(base)|cursorCookie=\(source.rawValue):\(credentialFingerprint)"
    }

    private func cursorCostCredentialFingerprintForDisplay() -> String? {
        #if DEBUG
        if let override = self._test_cursorCostCredentialFingerprintOverride { return override() }
        #endif
        return CookieHeaderCache.loadForDisplay(provider: .cursor)
            .map { CookieHeaderCache.credentialFingerprint($0.cookieHeader) }
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
            signature += "|settingsRevision=\(self.settings.costUsageSettingsRevision)|"
                + self.settings.costReportingPeriod.identity(
                    now: Date(),
                    calendar: self.settings.costUsageBucketCalendar)
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

    struct TokenRefreshPublicationScope {
        let publicationRevision: ProviderPublicationRevision
        let providerConfigRevision: UInt64
        let costSettingsRevision: UInt64
        let historyDays: Int
        let signature: String
    }

    struct TokenFetchFailureCooldown {
        let attemptedAt: Date
        let retryAfter: Date
        let scope: TokenRefreshPublicationScope
    }

    func tokenRefreshFailureIsCoolingDown(provider: UsageProvider, now: Date) -> Bool {
        guard let failure = self.tokenFetchFailureCooldowns[provider.instanceID],
              self.tokenFetchTTL != nil,
              now >= failure.attemptedAt,
              now < failure.retryAfter
        else { return false }
        // A failed query may have no snapshot, but still owns its account, settings, and provider lifecycle scope.
        return self.tokenRefreshPublicationDisposition(provider: provider, scope: failure.scope) == .current
    }

    func tokenRefreshPublicationScope(
        for provider: UsageProvider,
        historyDays: Int,
        costScopeSignature: String) -> TokenRefreshPublicationScope
    {
        TokenRefreshPublicationScope(
            publicationRevision: self.providerPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            costSettingsRevision: self.settings.costUsageSettingsRevision,
            historyDays: historyDays,
            signature: costScopeSignature)
    }

    enum TokenRefreshPublicationDisposition {
        case current
        case scopeChanged
        case unchangedCredentialMismatch
    }

    func tokenRefreshPublicationDisposition(
        provider: UsageProvider,
        scope: TokenRefreshPublicationScope,
        fetchedCredentialScopeFingerprint: String? = nil) -> TokenRefreshPublicationDisposition
    {
        guard self.providerPublicationRevisionIsCurrent(scope.publicationRevision, for: provider),
              self.settings.providerConfigRevision(for: provider) == scope.providerConfigRevision,
              self.settings.costUsageSettingsRevision == scope.costSettingsRevision,
              self.settings.isCostUsageEffectivelyEnabled(for: provider),
              self.isEnabled(provider),
              self.settings.costUsageHistoryDays == scope.historyDays
        else {
            return .scopeChanged
        }
        let currentSignature = self.tokenSnapshotScopeSignature(for: provider)
        if provider == .cursor,
           self.settings.cursorCookieSource == .auto,
           scope.signature.contains("|cursorCookie=auto:"),
           let fetchedCredentialScopeFingerprint
        {
            let resolvedSignature = self.cursorCostScopeSignature(
                historyDays: scope.historyDays,
                source: .auto,
                credentialFingerprint: fetchedCredentialScopeFingerprint)
            if currentSignature == resolvedSignature { return .current }
            // The fetched account is still unconfirmed; retry only after the attempted scope changes.
            return currentSignature == scope.signature ? .unchangedCredentialMismatch : .scopeChanged
        }
        return currentSignature == scope.signature ? .current : .scopeChanged
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
        let result: CostUsageTokenSnapshot? = switch provider {
        case .openai:
            snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot()
        case .mistral:
            snapshot?.mistralUsage?.toCostUsageTokenSnapshot(historyDays: windowDays)
        case .opencodego:
            // Web-only source mode and machines with no readable local database leave
            // `opencodegoUsage.daily` empty; a non-nil-but-dataless projection would still
            // surface a Cost row whose history submenu has nothing to render.
            snapshot?.opencodegoUsage.flatMap { usage in
                usage.daily.isEmpty ? nil : usage
                    .toCostUsageTokenSnapshot(historyDays: windowDays)
            }
        case .openrouter:
            snapshot?.costUsage
        case .xai:
            snapshot.flatMap { XAICostUsageMapping.tokenSnapshot(from: $0, historyDays: windowDays) }
        case .grok:
            self.grokLocalTokenSnapshot(from: snapshot, historyDays: windowDays)
        default:
            nil
        }
        guard historyDays == nil else { return result }
        return result?.selecting(
            self.settings.costReportingPeriod,
            now: Date(),
            calendar: self.settings.costUsageBucketCalendar)
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

    func clearCostUsageCache(
        fileManagerFactory: @escaping @Sendable () -> FileManager = { .default }) async -> String?
    {
        let errorMessage: String? = await Task.detached(priority: .utility) {
            let fileManager = fileManagerFactory()
            do {
                try fileManager.removeItem(at: Self.costUsageCacheDirectory(fileManager: fileManager))
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                    return nil
                }
                return error.localizedDescription
            }
            return nil
        }.value

        guard errorMessage == nil else { return errorMessage }

        self.clearTokenSnapshots()
        self.tokenErrors.removeAll()
        self.lastTokenFetchAt.removeAll()
        self.lastTokenFetchScope.removeAll()
        self.tokenFetchFailureCooldowns.removeAll()
        self.tokenFailureGates[.codex]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        return nil
    }

    /// Descriptors live in CodexBarCore and cannot localize, so the message is resolved here.
    /// `L` returns its argument unchanged for providers whose message is a plain English literal.
    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        L(ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.noDataMessage())
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
        let publicationScope: TokenRefreshPublicationScope
        let startedAt: Date
    }

    func commitTokenUsageResult(
        _ result: CostUsageTokenResult,
        context: TokenUsageRefreshContext) throws
    {
        let snapshot = result.snapshot
        try Task.checkCancellation()
        let completedCostScopeSignature = self.completedTokenCostScopeSignature(
            provider: context.provider,
            historyDays: context.historyDays,
            initialSignature: context.costScopeSignature,
            snapshot: snapshot)
        let disposition = self.tokenRefreshPublicationDisposition(
            provider: context.provider,
            scope: context.publicationScope,
            fetchedCredentialScopeFingerprint: snapshot.credentialScopeFingerprint)
        guard disposition == .current else {
            self.clearTokenFetchMetadataIfMatching(
                provider: context.provider,
                attemptedAt: context.now,
                costScopeSignature: context.costScopeSignature)
            if disposition == .scopeChanged {
                self.requestTokenRefreshAfterStaleCompletion(for: context.provider)
            }
            return
        }
        // An unavailable replacement root can retain the old report; retrying the same scope immediately loops.
        guard self.tokenAccountingScopeIsCurrent(result.accounting, for: context.provider) else {
            throw TokenSnapshotError.historyUnavailable
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
        self.tokenFetchFailureCooldowns.removeValue(forKey: provider.instanceID)
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
        self.tokenFetchFailureCooldowns.removeValue(forKey: provider.instanceID)
    }

    /// Timeouts keep the normal cadence; forbidden cost requests wait hours rather than retrying every tick.
    nonisolated static func tokenFetchFailureRetryDelay(_ error: Error, ttl: TimeInterval?) -> TimeInterval? {
        switch error {
        case CostUsageError.timedOut: ttl
        case CursorStatusProbeError.costRequestForbidden: ttl.map { max($0, 6 * 60 * 60) }
        default: nil
        }
    }

    func tokenCostIsAccountAgnostic(for provider: UsageProvider) -> Bool {
        // Provider-specific by design: only Codex's explicit ambient scope spans local accounts.
        provider == .codex && self.tokenCostScope(for: provider).signature == "codex:ambient"
    }
}
