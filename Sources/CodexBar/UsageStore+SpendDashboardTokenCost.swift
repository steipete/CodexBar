import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    nonisolated static func usesSpendDashboardIndependentTokenSnapshot(_ provider: UsageProvider) -> Bool {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost
            && !self.tokenCostRequiresProviderSnapshot(provider)
            // Provider-specific by design: Codex already scans the dashboard window in SpendDashboardSource.load.
            && provider != .codex
    }

    func spendDashboardTokenSnapshotPublicationForCurrentConfig(
        for provider: UsageProvider) -> CurrentProviderConfigTokenPublication?
    {
        guard let publication = self.spendDashboardTokenPublications[provider.instanceID],
              publication.providerConfigRevision == self.settings.providerConfigRevision(for: provider),
              publication.scopeSignature == self.spendDashboardTokenSnapshotScopeSignature(for: provider)
        else { return nil }
        return CurrentProviderConfigTokenPublication(
            snapshot: publication.snapshot,
            publicationRevision: publication.publicationRevision)
    }

    func spendDashboardTokenSnapshotPublicationRevision(for provider: UsageProvider) -> UInt64 {
        self.spendDashboardTokenPublicationRevisions[provider.instanceID] ?? 0
    }

    func clearSpendDashboardTokenSnapshot(for provider: UsageProvider) {
        self.spendDashboardTokenPublications.removeValue(forKey: provider.instanceID)
    }

    func discardSpendDashboardTokenPublicationsIfCostUsageDisabled() {
        guard !self.settings.costUsageEnabled else { return }
        self.spendDashboardTokenPublications.removeAll()
        self.spendDashboardTokenPublicationRevisions.removeAll()
    }

    func refreshSpendDashboardTokenUsageNow(for provider: UsageProvider, force: Bool) async {
        guard Self.usesSpendDashboardIndependentTokenSnapshot(provider) else { return }
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else {
            self.clearSpendDashboardTokenSnapshot(for: provider)
            return
        }

        guard self.settings.isCostUsageEffectivelyEnabled(for: provider) else {
            self.clearSpendDashboardTokenSnapshot(for: provider)
            return
        }

        guard self.isEnabled(provider) else {
            self.clearSpendDashboardTokenSnapshot(for: provider)
            return
        }

        // Provider-specific by design: Cursor Off skips dashboard cost the same way status fetching does.
        if provider == .cursor, self.settings.cursorCookieSource == .off {
            self.clearSpendDashboardTokenSnapshot(for: provider)
            return
        }

        guard !self.spendDashboardTokenRefreshInFlight.contains(provider.instanceID) else { return }

        let now = Date()
        let historyDays = SpendDashboardSource.scanDays
        guard case let .proceed(cursorCookieHeaderOverride) = self.prepareCursorCostCookie(for: provider) else {
            self.clearSpendDashboardTokenSnapshot(for: provider)
            return
        }
        let costScope = self.tokenCostScope(for: provider)
        let costScopeSignature = self.spendDashboardTokenSnapshotScopeSignature(for: provider)
        let publicationRevision = self.providerPublicationRevision(for: provider)
        let providerConfigRevision = self.settings.providerConfigRevision(for: provider)
        self.lastSpendDashboardTokenFetchAt[provider.instanceID] = now
        self.lastSpendDashboardTokenFetchScope[provider.instanceID] = costScopeSignature
        self.spendDashboardTokenRefreshInFlight.insert(provider.instanceID)
        defer { self.spendDashboardTokenRefreshInFlight.remove(provider.instanceID) }

        if let override = self._test_tokenUsageRefreshOverride {
            await override(provider, force)
            if Task.isCancelled {
                self.lastSpendDashboardTokenFetchAt.removeValue(forKey: provider.instanceID)
                self.lastSpendDashboardTokenFetchScope.removeValue(forKey: provider.instanceID)
            }
            return
        }

        do {
            let snapshot = try await self.loadTokenUsageSnapshot(
                provider: provider,
                force: force,
                now: now,
                codexHomePath: costScope.codexHomePath,
                historyDays: historyDays,
                cursorCookieHeaderOverride: cursorCookieHeaderOverride)
            try Task.checkCancellation()
            let completedCostScopeSignature = self.completedTokenCostScopeSignature(
                provider: provider,
                historyDays: historyDays,
                initialSignature: costScopeSignature,
                snapshot: snapshot,
                includeSettingsRevision: false)
            guard self.spendDashboardTokenRefreshPublicationIsCurrent(
                provider: provider,
                publicationRevision: publicationRevision,
                providerConfigRevision: providerConfigRevision,
                costScopeSignature: costScopeSignature,
                fetchedCredentialScopeFingerprint: snapshot.credentialScopeFingerprint)
            else {
                self.clearSpendDashboardTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
                return
            }
            self.lastSpendDashboardTokenFetchScope[provider.instanceID] = completedCostScopeSignature

            guard !snapshot.daily.isEmpty || snapshot.meteredCostUSD != nil else {
                self.publishSpendDashboardConfirmedEmptyTokenSnapshot(for: provider)
                return
            }
            self.publishSpendDashboardTokenSnapshot(snapshot, for: provider)
        } catch {
            guard self.spendDashboardTokenRefreshPublicationIsCurrent(
                provider: provider,
                publicationRevision: publicationRevision,
                providerConfigRevision: providerConfigRevision,
                costScopeSignature: costScopeSignature)
            else {
                self.clearSpendDashboardTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
                return
            }
            if error is CancellationError {
                self.clearSpendDashboardTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
                return
            }
            self.clearSpendDashboardTokenSnapshot(for: provider)
        }
    }

    private func publishSpendDashboardTokenSnapshot(
        _ snapshot: CostUsageTokenSnapshot,
        for provider: UsageProvider)
    {
        self.publishSpendDashboardTokenSnapshotState(snapshot, for: provider)
    }

    private func publishSpendDashboardConfirmedEmptyTokenSnapshot(for provider: UsageProvider) {
        self.publishSpendDashboardTokenSnapshotState(nil, for: provider)
    }

    #if DEBUG
    func _setSpendDashboardTokenSnapshotForTesting(
        _ snapshot: CostUsageTokenSnapshot?,
        for provider: UsageProvider)
    {
        if let snapshot {
            self.publishSpendDashboardTokenSnapshot(snapshot, for: provider)
        } else {
            self.publishSpendDashboardConfirmedEmptyTokenSnapshot(for: provider)
        }
    }
    #endif

    private func publishSpendDashboardTokenSnapshotState(
        _ snapshot: CostUsageTokenSnapshot?,
        for provider: UsageProvider)
    {
        self.spendDashboardTokenPublicationRevisions[provider.instanceID, default: 0] &+= 1
        self.spendDashboardTokenPublications[provider.instanceID] = TokenSnapshotPublication(
            snapshot: snapshot,
            publicationRevision: self.spendDashboardTokenSnapshotPublicationRevision(for: provider),
            providerConfigRevision: self.settings.providerConfigRevision(for: provider),
            scopeSignature: self.spendDashboardTokenSnapshotScopeSignature(for: provider))
        self.synchronizeSharedSpendDashboardAfterTokenPublication(for: provider)
    }

    private func spendDashboardTokenRefreshPublicationIsCurrent(
        provider: UsageProvider,
        publicationRevision: ProviderPublicationRevision,
        providerConfigRevision: UInt64,
        costScopeSignature: String,
        fetchedCredentialScopeFingerprint: String? = nil) -> Bool
    {
        guard self.providerPublicationRevisionIsCurrent(publicationRevision, for: provider),
              self.settings.providerConfigRevision(for: provider) == providerConfigRevision,
              self.settings.costUsageEnabled,
              self.isEnabled(provider)
        else {
            return false
        }
        let currentSignature = self.spendDashboardTokenSnapshotScopeSignature(for: provider)
        // Provider-specific by design: Cursor auto cookies complete the spend scope with the fetched fingerprint.
        if provider == .cursor,
           self.settings.cursorCookieSource == .auto,
           costScopeSignature.contains("|cursorCookie=auto:"),
           let fetchedCredentialScopeFingerprint
        {
            let resolvedSignature = self.cursorCostScopeSignature(
                historyDays: SpendDashboardSource.scanDays,
                source: .auto,
                credentialFingerprint: fetchedCredentialScopeFingerprint,
                includeSettingsRevision: false)
            return currentSignature == resolvedSignature
        }
        return currentSignature == costScopeSignature
    }

    private func clearSpendDashboardTokenFetchMetadataIfMatching(
        provider: UsageProvider,
        attemptedAt: Date,
        costScopeSignature: String)
    {
        guard self.lastSpendDashboardTokenFetchAt[provider.instanceID] == attemptedAt,
              self.lastSpendDashboardTokenFetchScope[provider.instanceID] == costScopeSignature
        else {
            return
        }
        self.lastSpendDashboardTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastSpendDashboardTokenFetchScope.removeValue(forKey: provider.instanceID)
    }
}
