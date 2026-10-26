import CodexBarCore
import Foundation

extension UsageStore {
    struct OpenAIDashboardRefreshContext {
        let targetEmail: String?
        let allowCurrentSnapshotFallback: Bool
        let expectedGuard: CodexAccountScopedRefreshGuard?
        let refreshTaskToken: UUID
        let allowCodexUsageBackfill: Bool
        let force: Bool
    }

    func applyOpenAIDashboardAndScheduleSubscriptionEnrichment(
        _ dashboard: OpenAIDashboardSnapshot,
        targetEmail: String?,
        context: OpenAIDashboardRefreshContext) async
    {
        if await self.applyOpenAIDashboard(
            dashboard,
            targetEmail: targetEmail,
            expectedGuard: context.expectedGuard,
            refreshTaskToken: context.refreshTaskToken,
            allowCodexUsageBackfill: context.allowCodexUsageBackfill)
        {
            self.scheduleOpenAISubscriptionMetadataEnrichment(
                dashboard: dashboard,
                targetEmail: targetEmail,
                expectedGuard: context.expectedGuard)
        }
    }

    /// Attaches metadata from a dashboard that has already passed the Codex authority check.
    @discardableResult
    func applyOpenAIDashboardSubscriptionMetadata(
        _ dashboard: OpenAIDashboardSnapshot) -> Bool
    {
        // Provider-specific by design: authorized OpenAI dashboard metadata attaches only to the active Codex snapshot.
        guard let currentUsage = self.snapshots[.codex] else { return false }

        let updatedUsage = currentUsage.withSubscriptionMetadata(
            expiresAt: dashboard.subscriptionExpiresAt,
            renewsAt: dashboard.subscriptionRenewsAt)
        self.snapshots[.codex] = updatedUsage
        let didChange = updatedUsage.subscriptionExpiresAt != currentUsage.subscriptionExpiresAt ||
            updatedUsage.subscriptionRenewsAt != currentUsage.subscriptionRenewsAt
        if didChange {
            self.persistWidgetSnapshot(reason: "dashboard-subscription-metadata")
        }
        return didChange
    }

    func scheduleOpenAISubscriptionMetadataEnrichment(
        dashboard: OpenAIDashboardSnapshot,
        targetEmail: String?,
        expectedGuard: CodexAccountScopedRefreshGuard?)
    {
        guard self.startupBehavior.automaticallyStartsBackgroundWork ||
            self._test_openAISubscriptionMetadataLoaderOverride != nil else { return }
        self.openAISubscriptionMetadataEnrichmentTask?.cancel()
        let token = UUID()
        self.openAISubscriptionMetadataEnrichmentToken = token
        let expectedGuard = expectedGuard ?? self.currentCodexOpenAIWebRefreshGuard()
        let cacheScope = self.codexCookieCacheScopeForOpenAIWeb()
        let log: (String) -> Void = { [weak self] line in self?.logOpenAIWeb(line) }
        self.openAISubscriptionMetadataEnrichmentTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.openAISubscriptionMetadataEnrichmentToken == token {
                    self.openAISubscriptionMetadataEnrichmentTask = nil
                    self.openAISubscriptionMetadataEnrichmentToken = nil
                }
            }
            let result: OpenAISubscriptionFetchResult = if let override = self
                ._test_openAISubscriptionMetadataLoaderOverride
            {
                await override(targetEmail)
            } else {
                await OpenAIDashboardFetcher().fetchSubscriptionMetadata(
                    accountEmail: targetEmail,
                    cacheScope: cacheScope,
                    logger: log)
            }
            await self.applyOpenAISubscriptionMetadataEnrichment(
                result,
                dashboard: dashboard,
                targetEmail: targetEmail,
                expectedGuard: expectedGuard,
                token: token)
        }
    }

    private func applyOpenAISubscriptionMetadataEnrichment(
        _ result: OpenAISubscriptionFetchResult,
        dashboard: OpenAIDashboardSnapshot,
        targetEmail: String?,
        expectedGuard: CodexAccountScopedRefreshGuard,
        token: UUID) async
    {
        // Provider-specific by design: optional OpenAI billing work requires active Codex web access.
        guard !Task.isCancelled,
              self.isEnabled(.codex),
              self.settings.openAIWebAccessEnabled,
              self.settings.codexCookieSource.isEnabled,
              self.openAISubscriptionMetadataEnrichmentToken == token,
              result.succeeded
        else { return }
        // The captured dates belong to this accepted dashboard, not a later same-email refresh.
        guard self.openAIDashboardAttachmentAuthorized, self.openAIDashboard == dashboard else {
            self.logOpenAIWeb("subscription metadata enrichment skipped: dashboard changed")
            return
        }
        let enrichedDashboard = dashboard.withSubscriptionMetadata(result.metadata)
        let authority = self.evaluateCodexDashboardAuthority(
            dashboard: enrichedDashboard,
            sourceKind: .liveWeb,
            routingTargetEmail: targetEmail)
        guard authority.decision.disposition == .attach,
              authority.decision.allowedEffects.contains(.subscriptionMetadataAttachment)
        else {
            self.logOpenAIWeb("subscription metadata enrichment skipped: authority=\(authority.decision.disposition)")
            return
        }
        if !self.shouldApplyOpenAIDashboardRefreshGuard(
            expectedGuard: expectedGuard,
            routingTargetEmail: targetEmail)
        {
            self.logOpenAIWeb("subscription metadata enrichment skipped: refresh guard changed")
            return
        }
        self.openAIDashboard = enrichedDashboard
        self.lastOpenAIDashboardSnapshot = enrichedDashboard
        let didPersist = self.applyOpenAIDashboardSubscriptionMetadata(enrichedDashboard)
        self
            .logOpenAIWeb(
                "subscription metadata enrichment \(didPersist ? "persisted" : "unchanged"): authority=attach")
        if let attachedEmail = self.codexDashboardAttachmentEmail(from: authority.input), !attachedEmail.isEmpty {
            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
                accountEmail: attachedEmail,
                snapshot: enrichedDashboard))
        }
    }
}
