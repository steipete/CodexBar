import CodexBarCore
import Foundation

// MARK: - OpenAI web lifecycle

extension UsageStore {
    private struct OpenAIDashboardRefreshContext {
        let targetEmail: String?
        let allowCurrentSnapshotFallback: Bool
        let expectedGuard: CodexAccountScopedRefreshGuard?
        let refreshTaskToken: UUID
        let allowCodexUsageBackfill: Bool
    }

    private static let openAIWebRefreshMultiplier: TimeInterval = 5
    private static let openAIWebPrimaryFetchTimeout: TimeInterval = 15
    private static let openAIWebRetryFetchTimeout: TimeInterval = 8

    private func openAIWebRefreshIntervalSeconds() -> TimeInterval {
        let base = max(self.settings.refreshFrequency.seconds ?? 0, 120)
        return base * Self.openAIWebRefreshMultiplier
    }

    func requestOpenAIDashboardRefreshIfStale(reason: String) {
        guard self.isEnabled(.codex), self.settings.codexCookieSource.isEnabled else { return }
        let now = Date()
        let refreshInterval = self.openAIWebRefreshIntervalSeconds()
        let lastUpdatedAt = self.openAIDashboard?.updatedAt ?? self.lastOpenAIDashboardSnapshot?.updatedAt
        if let lastUpdatedAt, now.timeIntervalSince(lastUpdatedAt) < refreshInterval { return }
        let stamp = now.formatted(date: .abbreviated, time: .shortened)
        self.logOpenAIWeb("[\(stamp)] OpenAI web refresh request: \(reason)")
        let expectedGuard = self.currentCodexOpenAIWebRefreshGuard()
        Task { await self.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard) }
    }

    func applyOpenAIDashboard(
        _ dash: OpenAIDashboardSnapshot,
        targetEmail: String?,
        expectedGuard: CodexAccountScopedRefreshGuard? = nil,
        refreshTaskToken: UUID? = nil,
        allowCodexUsageBackfill: Bool = true) async
    {
        guard self.shouldApplyOpenAIDashboardRefreshTask(token: refreshTaskToken) else { return }
        let resolvedAccountEmail = targetEmail ?? dash.signedInEmail
        let resolvedAccountKey = Self.normalizeCodexAccountScopedKey(resolvedAccountEmail)
        if let expectedGuard,
           !self.shouldApplyOpenAIDashboardResult(
               expectedGuard: expectedGuard,
               dashboardAccountEmail: resolvedAccountEmail)
        {
            return
        }

        await MainActor.run {
            self.openAIDashboard = dash
            self.lastOpenAIDashboardError = nil
            self.lastOpenAIDashboardSnapshot = dash
            self.openAIDashboardRequiresLogin = false
            // Only fill gaps; OAuth/CLI remain the primary sources for usage + credits.
            if allowCodexUsageBackfill,
               self.snapshots[.codex] == nil,
               let usage = dash.toUsageSnapshot(provider: .codex, accountEmail: targetEmail)
            {
                self.snapshots[.codex] = usage
                self.errors[.codex] = nil
                self.failureGates[.codex]?.recordSuccess()
                self.lastSourceLabels[.codex] = "openai-web"
                self.rememberLiveSystemCodexEmailIfNeeded(usage.accountEmail(for: .codex))
            }
            if self.credits == nil, let credits = dash.toCreditsSnapshot() {
                self.credits = credits
                self.lastCreditsSnapshot = credits
                self.lastCreditsSnapshotAccountKey = resolvedAccountKey
                self.lastCreditsError = nil
                self.creditsFailureStreak = 0
            }
            self.seedCodexAccountScopedRefreshGuard(accountEmail: resolvedAccountEmail)
        }

        if let email = targetEmail, !email.isEmpty {
            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(accountEmail: email, snapshot: dash))
        }
        self.backfillCodexHistoricalFromDashboardIfNeeded(dash)
    }

    func applyOpenAIDashboardFailure(
        message: String,
        expectedGuard: CodexAccountScopedRefreshGuard? = nil,
        refreshTaskToken: UUID? = nil) async
    {
        guard self.shouldApplyOpenAIDashboardRefreshTask(token: refreshTaskToken) else { return }
        if let expectedGuard,
           !self.shouldApplyOpenAIWebNonSuccessResult(expectedGuard: expectedGuard)
        {
            return
        }
        if self.openAIWebManagedTargetStoreIsUnreadable() {
            await self.failClosedRefreshForUnreadableManagedCodexStore()
            return
        }
        if self.openAIWebManagedTargetIsMissing() {
            await self.failClosedRefreshForMissingManagedCodexTarget()
            return
        }

        await MainActor.run {
            if let cached = self.lastOpenAIDashboardSnapshot {
                self.openAIDashboard = cached
                let stamp = cached.updatedAt.formatted(date: .abbreviated, time: .shortened)
                self.lastOpenAIDashboardError =
                    "Last OpenAI dashboard refresh failed: \(message). Cached values from \(stamp)."
            } else {
                self.lastOpenAIDashboardError = message
                self.openAIDashboard = nil
            }
        }
    }

    func applyOpenAIDashboardMismatchFailure(
        signedInEmail: String,
        expectedEmail: String?,
        expectedGuard: CodexAccountScopedRefreshGuard? = nil,
        refreshTaskToken: UUID? = nil) async
    {
        guard self.shouldApplyOpenAIDashboardRefreshTask(token: refreshTaskToken) else { return }
        if let expectedGuard,
           !self.shouldApplyOpenAIWebNonSuccessResult(expectedGuard: expectedGuard)
        {
            return
        }
        await MainActor.run {
            self.failClosedOpenAIDashboardSnapshot()
            self.lastOpenAIDashboardError = [
                "OpenAI dashboard signed in as \(signedInEmail), but Codex uses \(expectedEmail ?? "unknown").",
                "Switch accounts in your browser and update OpenAI cookies in Providers → Codex.",
            ].joined(separator: " ")
        }
    }

    func applyOpenAIDashboardLoginRequiredFailure(
        expectedGuard: CodexAccountScopedRefreshGuard? = nil,
        refreshTaskToken: UUID? = nil) async
    {
        guard self.shouldApplyOpenAIDashboardRefreshTask(token: refreshTaskToken) else { return }
        if let expectedGuard,
           !self.shouldApplyOpenAIWebNonSuccessResult(expectedGuard: expectedGuard)
        {
            return
        }
        if self.openAIWebManagedTargetStoreIsUnreadable() {
            await self.failClosedRefreshForUnreadableManagedCodexStore()
            return
        }
        if self.openAIWebManagedTargetIsMissing() {
            await self.failClosedRefreshForMissingManagedCodexTarget()
            return
        }

        await MainActor.run {
            self.lastOpenAIDashboardError = [
                "OpenAI web access requires a signed-in chatgpt.com session.",
                "Sign in using \(self.codexBrowserCookieOrder.loginHint), " +
                    "then update OpenAI cookies in Providers → Codex.",
            ].joined(separator: " ")
            self.openAIDashboard = self.lastOpenAIDashboardSnapshot
            self.openAIDashboardRequiresLogin = true
        }
    }

    private func failClosedOpenAIDashboardSnapshot() {
        self.openAIDashboard = nil
        self.lastOpenAIDashboardSnapshot = nil
        self.openAIDashboardRequiresLogin = true
    }

    func refreshOpenAIDashboardIfNeeded(
        force: Bool = false,
        expectedGuard: CodexAccountScopedRefreshGuard? = nil,
        bypassCoalescing: Bool = false,
        allowCodexUsageBackfill: Bool = true) async
    {
        guard self.isEnabled(.codex), self.settings.codexCookieSource.isEnabled else {
            self.resetOpenAIWebState()
            return
        }
        if self.openAIWebManagedTargetStoreIsUnreadable() {
            await self.failClosedRefreshForUnreadableManagedCodexStore()
            return
        }
        if self.openAIWebManagedTargetIsMissing() {
            await self.failClosedRefreshForMissingManagedCodexTarget()
            return
        }

        let allowCurrentSnapshotFallback = expectedGuard?.source == .liveSystem && expectedGuard?.accountKey == nil
        let targetEmail = self.currentCodexOpenAIWebTargetEmail(
            allowCurrentSnapshotFallback: allowCurrentSnapshotFallback,
            allowLastKnownLiveFallback: expectedGuard?.accountKey != nil)
        let refreshKey = self.openAIDashboardRefreshKey(targetEmail: targetEmail, expectedGuard: expectedGuard)
        if !bypassCoalescing,
           let task = self.openAIDashboardRefreshTask,
           self.openAIDashboardRefreshTaskKey == refreshKey
        {
            await task.value
            return
        }
        self.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: targetEmail)

        let now = Date()
        let minInterval = self.openAIWebRefreshIntervalSeconds()
        if !force,
           !self.openAIWebAccountDidChange,
           self.lastOpenAIDashboardError == nil,
           let snapshot = self.lastOpenAIDashboardSnapshot,
           now.timeIntervalSince(snapshot.updatedAt) < minInterval
        {
            return
        }

        let taskToken = UUID()
        let context = OpenAIDashboardRefreshContext(
            targetEmail: targetEmail,
            allowCurrentSnapshotFallback: allowCurrentSnapshotFallback,
            expectedGuard: expectedGuard,
            refreshTaskToken: taskToken,
            allowCodexUsageBackfill: allowCodexUsageBackfill)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performOpenAIDashboardRefreshIfNeeded(context)
        }
        self.openAIDashboardRefreshTask = task
        self.openAIDashboardRefreshTaskKey = refreshKey
        self.openAIDashboardRefreshTaskToken = taskToken
        await task.value
        if self.openAIDashboardRefreshTaskToken == taskToken {
            self.openAIDashboardRefreshTask = nil
            self.openAIDashboardRefreshTaskKey = nil
            self.openAIDashboardRefreshTaskToken = nil
        }
    }

    private func performOpenAIDashboardRefreshIfNeeded(_ context: OpenAIDashboardRefreshContext) async {
        self.openAIDashboardCookieImportStatus = nil
        var latestCookieImportStatus: String?
        if self.openAIWebDebugLines.isEmpty {
            self.resetOpenAIWebDebugLog(context: "refresh")
        } else {
            let stamp = Date().formatted(date: .abbreviated, time: .shortened)
            self.logOpenAIWeb("[\(stamp)] OpenAI web refresh start")
        }
        let log: (String) -> Void = { [weak self] line in
            guard let self else { return }
            self.logOpenAIWeb(line)
        }

        do {
            let normalized = context.targetEmail?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var effectiveEmail = context.targetEmail

            // Use a per-email persistent `WKWebsiteDataStore` so multiple dashboard sessions can coexist.
            // Strategy:
            // - Try the existing per-email WebKit cookie store first (fast; avoids Keychain prompts).
            // - On login-required or account mismatch, import cookies from the configured browser order and retry once.
            if self.openAIWebAccountDidChange, let targetEmail = context.targetEmail, !targetEmail.isEmpty {
                // On account switches, proactively re-import cookies so we don't show stale data from the previous
                // user.
                let imported = await self.importOpenAIDashboardCookiesIfNeeded(
                    targetEmail: targetEmail,
                    force: true)
                latestCookieImportStatus = self.currentOpenAIDashboardCookieImportStatus()
                if await self.abortOpenAIDashboardRetryAfterImportFailure(
                    importedEmail: imported,
                    targetEmail: targetEmail,
                    expectedGuard: context.expectedGuard,
                    cookieImportStatus: latestCookieImportStatus,
                    refreshTaskToken: context.refreshTaskToken)
                {
                    self.openAIWebAccountDidChange = false
                    return
                }
                if let imported {
                    effectiveEmail = imported
                }
                self.openAIWebAccountDidChange = false
            }

            var dash = try await self.loadLatestOpenAIDashboard(
                accountEmail: effectiveEmail,
                logger: log,
                timeout: Self.openAIWebPrimaryFetchTimeout)

            if self.dashboardEmailMismatch(expected: normalized, actual: dash.signedInEmail) {
                if let imported = await self.importOpenAIDashboardCookiesIfNeeded(
                    targetEmail: context.targetEmail,
                    force: true)
                {
                    effectiveEmail = imported
                }
                latestCookieImportStatus = self.currentOpenAIDashboardCookieImportStatus()
                dash = try await self.loadLatestOpenAIDashboard(
                    accountEmail: effectiveEmail,
                    logger: log,
                    timeout: Self.openAIWebRetryFetchTimeout)
            }

            if self.dashboardEmailMismatch(expected: normalized, actual: dash.signedInEmail) {
                let signedIn = dash.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                await self.applyOpenAIDashboardMismatchFailure(
                    signedInEmail: signedIn,
                    expectedEmail: normalized,
                    expectedGuard: context.expectedGuard,
                    refreshTaskToken: context.refreshTaskToken)
                return
            }

            await self.applyOpenAIDashboard(
                dash,
                targetEmail: effectiveEmail,
                expectedGuard: context.expectedGuard,
                refreshTaskToken: context.refreshTaskToken,
                allowCodexUsageBackfill: context.allowCodexUsageBackfill)
        } catch let OpenAIDashboardFetcher.FetchError.noDashboardData(body) {
            await self.retryOpenAIDashboardAfterNoData(
                body: body,
                context: context,
                latestCookieImportStatus: &latestCookieImportStatus,
                logger: log)
        } catch OpenAIDashboardFetcher.FetchError.loginRequired {
            await self.retryOpenAIDashboardAfterLoginRequired(
                context: context,
                latestCookieImportStatus: &latestCookieImportStatus,
                logger: log)
        } catch {
            let message = self.preferredOpenAIDashboardFailureMessage(
                error: error,
                targetEmail: context.targetEmail,
                cookieImportStatus: latestCookieImportStatus)
            await self.applyOpenAIDashboardFailure(
                message: message,
                expectedGuard: context.expectedGuard,
                refreshTaskToken: context.refreshTaskToken)
        }
    }

    private func retryOpenAIDashboardAfterNoData(
        body: String,
        context: OpenAIDashboardRefreshContext,
        latestCookieImportStatus: inout String?,
        logger: @escaping (String) -> Void) async
    {
        let targetEmail = self.currentCodexOpenAIWebTargetEmail(
            allowCurrentSnapshotFallback: context.allowCurrentSnapshotFallback,
            allowLastKnownLiveFallback: context.expectedGuard?.accountKey != nil)
        var effectiveEmail = targetEmail
        let imported = await self.importOpenAIDashboardCookiesIfNeeded(targetEmail: targetEmail, force: true)
        latestCookieImportStatus = self.currentOpenAIDashboardCookieImportStatus()
        if await self.abortOpenAIDashboardRetryAfterImportFailure(
            importedEmail: imported,
            targetEmail: targetEmail,
            expectedGuard: context.expectedGuard,
            cookieImportStatus: latestCookieImportStatus,
            refreshTaskToken: context.refreshTaskToken)
        {
            return
        }
        if let imported {
            effectiveEmail = imported
        }
        do {
            let dash = try await self.loadLatestOpenAIDashboard(
                accountEmail: effectiveEmail,
                logger: logger,
                timeout: Self.openAIWebRetryFetchTimeout)
            await self.applyOpenAIDashboard(
                dash,
                targetEmail: effectiveEmail,
                expectedGuard: context.expectedGuard,
                refreshTaskToken: context.refreshTaskToken,
                allowCodexUsageBackfill: context.allowCodexUsageBackfill)
        } catch let OpenAIDashboardFetcher.FetchError.noDashboardData(retryBody) {
            let finalBody = retryBody.isEmpty ? body : retryBody
            let message = self.openAIDashboardFriendlyError(
                body: finalBody,
                targetEmail: targetEmail,
                cookieImportStatus: latestCookieImportStatus)
                ?? OpenAIDashboardFetcher.FetchError.noDashboardData(body: finalBody).localizedDescription
            await self.applyOpenAIDashboardFailure(
                message: message,
                expectedGuard: context.expectedGuard,
                refreshTaskToken: context.refreshTaskToken)
        } catch {
            let message = self.preferredOpenAIDashboardFailureMessage(
                error: error,
                targetEmail: targetEmail,
                cookieImportStatus: latestCookieImportStatus)
            await self.applyOpenAIDashboardFailure(
                message: message,
                expectedGuard: context.expectedGuard,
                refreshTaskToken: context.refreshTaskToken)
        }
    }

    private func retryOpenAIDashboardAfterLoginRequired(
        context: OpenAIDashboardRefreshContext,
        latestCookieImportStatus: inout String?,
        logger: @escaping (String) -> Void) async
    {
        let targetEmail = self.currentCodexOpenAIWebTargetEmail(
            allowCurrentSnapshotFallback: context.allowCurrentSnapshotFallback,
            allowLastKnownLiveFallback: context.expectedGuard?.accountKey != nil)
        var effectiveEmail = targetEmail
        let imported = await self.importOpenAIDashboardCookiesIfNeeded(targetEmail: targetEmail, force: true)
        latestCookieImportStatus = self.currentOpenAIDashboardCookieImportStatus()
        if await self.abortOpenAIDashboardRetryAfterImportFailure(
            importedEmail: imported,
            targetEmail: targetEmail,
            expectedGuard: context.expectedGuard,
            cookieImportStatus: latestCookieImportStatus,
            refreshTaskToken: context.refreshTaskToken)
        {
            return
        }
        if let imported {
            effectiveEmail = imported
        }
        do {
            let dash = try await self.loadLatestOpenAIDashboard(
                accountEmail: effectiveEmail,
                logger: logger,
                timeout: Self.openAIWebRetryFetchTimeout)
            await self.applyOpenAIDashboard(
                dash,
                targetEmail: effectiveEmail,
                expectedGuard: context.expectedGuard,
                refreshTaskToken: context.refreshTaskToken,
                allowCodexUsageBackfill: context.allowCodexUsageBackfill)
        } catch OpenAIDashboardFetcher.FetchError.loginRequired {
            await self.applyOpenAIDashboardLoginRequiredFailure(
                expectedGuard: context.expectedGuard,
                refreshTaskToken: context.refreshTaskToken)
        } catch {
            let message = self.preferredOpenAIDashboardFailureMessage(
                error: error,
                targetEmail: targetEmail,
                cookieImportStatus: latestCookieImportStatus)
            await self.applyOpenAIDashboardFailure(
                message: message,
                expectedGuard: context.expectedGuard,
                refreshTaskToken: context.refreshTaskToken)
        }
    }

    // MARK: - OpenAI web account switching

    /// Detect Codex account email changes and clear stale OpenAI web state so the UI can't show the wrong user.
    /// This does not delete other per-email WebKit cookie stores (we keep multiple accounts around).
    func handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: String?) {
        let normalized = targetEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let normalized, !normalized.isEmpty else { return }

        let previous = self.lastOpenAIDashboardTargetEmail
        self.lastOpenAIDashboardTargetEmail = normalized

        if let previous,
           !previous.isEmpty,
           previous != normalized
        {
            let stamp = Date().formatted(date: .abbreviated, time: .shortened)
            self.logOpenAIWeb(
                "[\(stamp)] Codex account changed: \(previous) → \(normalized); " +
                    "clearing OpenAI web snapshot")
            self.openAIWebAccountDidChange = true
            self.openAIDashboard = nil
            self.lastOpenAIDashboardSnapshot = nil
            self.lastOpenAIDashboardError = nil
            self.openAIDashboardRequiresLogin = true
            self.openAIDashboardCookieImportStatus = "Codex account changed; importing browser cookies…"
            self.lastOpenAIDashboardCookieImportAttemptAt = nil
            self.lastOpenAIDashboardCookieImportEmail = nil
        }
    }

    func importOpenAIDashboardBrowserCookiesNow() async {
        self.resetOpenAIWebDebugLog(context: "manual import")
        let targetEmail = self.currentCodexOpenAIWebTargetEmail(
            allowCurrentSnapshotFallback: true,
            allowLastKnownLiveFallback: false)
        _ = await self.importOpenAIDashboardCookiesIfNeeded(targetEmail: targetEmail, force: true)
        let expectedGuard = self.currentCodexOpenAIWebRefreshGuard()
        await self.refreshOpenAIDashboardIfNeeded(
            force: true,
            expectedGuard: expectedGuard,
            bypassCoalescing: true)
    }

    func currentCodexOpenAIWebTargetEmail(
        allowCurrentSnapshotFallback: Bool,
        allowLastKnownLiveFallback: Bool) -> String?
    {
        switch self.settings.codexResolvedActiveSource {
        case .liveSystem:
            let liveSystem = self.settings.codexAccountReconciliationSnapshot.liveSystemAccount?.email
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let liveSystem, !liveSystem.isEmpty {
                self.lastKnownLiveSystemCodexEmail = liveSystem
                return liveSystem
            }

            if allowCurrentSnapshotFallback,
               let snapshotEmail = self.snapshots[.codex]?.accountEmail(for: .codex)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
                   !snapshotEmail.isEmpty
            {
                self.lastKnownLiveSystemCodexEmail = snapshotEmail
                return snapshotEmail
            }

            if allowLastKnownLiveFallback {
                let lastKnown = self.lastKnownLiveSystemCodexEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let lastKnown, !lastKnown.isEmpty { return lastKnown }
            }
            return nil
        case .managedAccount:
            return self.codexAccountEmailForOpenAIDashboard()
        }
    }

    private func shouldApplyOpenAIWebNonSuccessResult(expectedGuard: CodexAccountScopedRefreshGuard) -> Bool {
        if expectedGuard.accountKey != nil {
            return self.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard)
        }

        guard case .liveSystem = expectedGuard.source else { return false }
        let currentGuard = self.currentCodexOpenAIWebRefreshGuard()
        guard currentGuard.source == expectedGuard.source else { return false }
        guard currentGuard.accountKey == nil else { return false }
        return self.currentCodexOpenAIWebTargetEmail(
            allowCurrentSnapshotFallback: true,
            allowLastKnownLiveFallback: false) != nil
    }

    private func openAIDashboardRefreshKey(
        targetEmail: String?,
        expectedGuard: CodexAccountScopedRefreshGuard?) -> String
    {
        let source = String(describing: expectedGuard?.source ?? self.settings.codexResolvedActiveSource)
        let accountKey = Self.normalizeCodexAccountScopedKey(targetEmail ?? expectedGuard?.accountKey) ?? "unknown"
        return "\(source)|\(accountKey)"
    }

    private func actionableOpenAIDashboardImportFailure(targetEmail: String?) -> String? {
        self.actionableOpenAIDashboardImportFailure(
            targetEmail: targetEmail,
            cookieImportStatus: self.openAIDashboardCookieImportStatus)
    }

    private func actionableOpenAIDashboardImportFailure(
        targetEmail: String?,
        cookieImportStatus: String?) -> String?
    {
        let status = cookieImportStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status, !status.isEmpty else { return nil }

        if status.localizedCaseInsensitiveContains("openai cookies are for") {
            return "\(status) Switch chatgpt.com account, then refresh OpenAI cookies."
        }
        if status.localizedCaseInsensitiveContains("no signed-in openai web session found") {
            let targetLabel = targetEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountLabel = (targetLabel?.isEmpty == false) ? targetLabel! : "your OpenAI account"
            return "\(status) Sign in to chatgpt.com as \(accountLabel), then refresh OpenAI cookies."
        }
        if status.localizedCaseInsensitiveContains("openai cookie import failed")
            || status.localizedCaseInsensitiveContains("browser cookie import failed")
        {
            return status
        }
        return nil
    }

    private func preferredOpenAIDashboardFailureMessage(
        error: Error,
        targetEmail: String?,
        cookieImportStatus: String?) -> String
    {
        if let actionable = self.actionableOpenAIDashboardImportFailure(
            targetEmail: targetEmail,
            cookieImportStatus: cookieImportStatus)
        {
            return actionable
        }
        return error.localizedDescription
    }

    private func abortOpenAIDashboardRetryAfterImportFailure(
        importedEmail: String?,
        targetEmail: String?,
        expectedGuard: CodexAccountScopedRefreshGuard?,
        cookieImportStatus: String?,
        refreshTaskToken: UUID) async -> Bool
    {
        guard importedEmail == nil,
              let message = self.actionableOpenAIDashboardImportFailure(
                  targetEmail: targetEmail,
                  cookieImportStatus: cookieImportStatus)
        else {
            return false
        }
        await self.applyOpenAIDashboardFailure(
            message: message,
            expectedGuard: expectedGuard,
            refreshTaskToken: refreshTaskToken)
        return true
    }

    private func shouldApplyOpenAIDashboardRefreshTask(token: UUID?) -> Bool {
        guard let token else { return true }
        return self.openAIDashboardRefreshTaskToken == token
    }

    func invalidateOpenAIDashboardRefreshTask() {
        self.openAIDashboardRefreshTask?.cancel()
        self.openAIDashboardRefreshTask = nil
        self.openAIDashboardRefreshTaskKey = nil
        self.openAIDashboardRefreshTaskToken = nil
    }

    private func currentOpenAIDashboardCookieImportStatus() -> String? {
        self.openAIDashboardCookieImportStatus
    }

    private func loadLatestOpenAIDashboard(
        accountEmail: String?,
        logger: @escaping (String) -> Void,
        timeout: TimeInterval) async throws -> OpenAIDashboardSnapshot
    {
        if let override = self._test_openAIDashboardLoaderOverride {
            return try await override(accountEmail, logger, timeout)
        }
        return try await OpenAIDashboardFetcher().loadLatestDashboard(
            accountEmail: accountEmail,
            logger: logger,
            debugDumpHTML: timeout != Self.openAIWebPrimaryFetchTimeout,
            timeout: timeout)
    }

    private func failClosedForUnreadableManagedCodexStore() async -> String? {
        await MainActor.run {
            self.failClosedOpenAIDashboardSnapshot()
            self.openAIDashboardCookieImportStatus = [
                "Managed Codex account data is unavailable.",
                "Fix the managed account store before importing OpenAI cookies.",
            ].joined(separator: " ")
        }
        return nil
    }

    private func failClosedRefreshForUnreadableManagedCodexStore() async {
        await MainActor.run {
            self.failClosedOpenAIDashboardSnapshot()
            self.lastOpenAIDashboardError = [
                "Managed Codex account data is unavailable.",
                "Fix the managed account store before refreshing OpenAI web data.",
            ].joined(separator: " ")
        }
    }

    private func failClosedForMissingManagedCodexTarget() async -> String? {
        await MainActor.run {
            self.failClosedOpenAIDashboardSnapshot()
            self.openAIDashboardCookieImportStatus = [
                "The selected managed Codex account is unavailable.",
                "Pick another Codex account before importing OpenAI cookies.",
            ].joined(separator: " ")
        }
        return nil
    }

    private func failClosedRefreshForMissingManagedCodexTarget() async {
        await MainActor.run {
            self.failClosedOpenAIDashboardSnapshot()
            self.lastOpenAIDashboardError = [
                "The selected managed Codex account is unavailable.",
                "Pick another Codex account before refreshing OpenAI web data.",
            ].joined(separator: " ")
        }
    }

    private func openAIWebCookieImportShouldFailClosed() async -> Bool {
        if self.openAIWebManagedTargetStoreIsUnreadable() {
            _ = await self.failClosedForUnreadableManagedCodexStore()
            return true
        }
        if self.openAIWebManagedTargetIsMissing() {
            _ = await self.failClosedForMissingManagedCodexTarget()
            return true
        }
        return false
    }

    func importOpenAIDashboardCookiesIfNeeded(targetEmail: String?, force: Bool) async -> String? {
        if await self.openAIWebCookieImportShouldFailClosed() {
            return nil
        }

        let normalizedTarget = targetEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowAnyAccount = normalizedTarget == nil || normalizedTarget?.isEmpty == true
        let cookieSource = self.settings.codexCookieSource
        let cacheScope = self.codexCookieCacheScopeForOpenAIWeb()

        let now = Date()
        let lastEmail = self.lastOpenAIDashboardCookieImportEmail
        let lastAttempt = self.lastOpenAIDashboardCookieImportAttemptAt ?? .distantPast

        let shouldAttempt: Bool = if force {
            true
        } else {
            if allowAnyAccount {
                now.timeIntervalSince(lastAttempt) > 300
            } else {
                self.openAIDashboardRequiresLogin &&
                    (
                        lastEmail?.lowercased() != normalizedTarget?.lowercased() || now
                            .timeIntervalSince(lastAttempt) > 300)
            }
        }

        guard shouldAttempt else { return normalizedTarget }
        self.lastOpenAIDashboardCookieImportEmail = normalizedTarget
        self.lastOpenAIDashboardCookieImportAttemptAt = now

        let stamp = now.formatted(date: .abbreviated, time: .shortened)
        let targetLabel = normalizedTarget ?? "unknown"
        self.logOpenAIWeb("[\(stamp)] import start (target=\(targetLabel))")

        do {
            let log: (String) -> Void = { [weak self] message in
                guard let self else { return }
                self.logOpenAIWeb(message)
            }

            let result: OpenAIDashboardBrowserCookieImporter.ImportResult
            if let override = self._test_openAIDashboardCookieImportOverride {
                result = try await override(normalizedTarget, allowAnyAccount, cookieSource, cacheScope, log)
            } else {
                let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: self.browserDetection)
                switch cookieSource {
                case .manual:
                    self.settings.ensureCodexCookieLoaded()
                    // Manual OpenAI cookies still come from one provider-level setting. Auto-imported cookies are
                    // isolated per managed account, but a manual header is an explicit override owned by settings,
                    // so switching managed accounts does not currently swap it underneath the user.
                    let manualHeader = self.settings.codexCookieHeader
                    guard CookieHeaderNormalizer.normalize(manualHeader) != nil else {
                        throw OpenAIDashboardBrowserCookieImporter.ImportError.manualCookieHeaderInvalid
                    }
                    result = try await importer.importManualCookies(
                        cookieHeader: manualHeader,
                        intoAccountEmail: normalizedTarget,
                        allowAnyAccount: allowAnyAccount,
                        cacheScope: cacheScope,
                        logger: log)
                case .auto:
                    result = try await importer.importBestCookies(
                        intoAccountEmail: normalizedTarget,
                        allowAnyAccount: allowAnyAccount,
                        cacheScope: cacheScope,
                        logger: log)
                case .off:
                    result = OpenAIDashboardBrowserCookieImporter.ImportResult(
                        sourceLabel: "Off",
                        cookieCount: 0,
                        signedInEmail: normalizedTarget,
                        matchesCodexEmail: true)
                }
            }
            let effectiveEmail = result.signedInEmail?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
                ? result.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
                : normalizedTarget
            self.lastOpenAIDashboardCookieImportEmail = effectiveEmail ?? normalizedTarget
            await MainActor.run {
                let signed = result.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
                let matchText = result.matchesCodexEmail ? "matches Codex" : "does not match Codex"
                let sourceLabel = switch cookieSource {
                case .manual:
                    "Manual cookie header"
                case .auto:
                    "\(result.sourceLabel) cookies"
                case .off:
                    "OpenAI cookies disabled"
                }
                if let signed, !signed.isEmpty {
                    self.openAIDashboardCookieImportStatus =
                        allowAnyAccount
                            ? [
                                "Using \(sourceLabel) (\(result.cookieCount)).",
                                "Signed in as \(signed).",
                            ].joined(separator: " ")
                            : [
                                "Using \(sourceLabel) (\(result.cookieCount)).",
                                "Signed in as \(signed) (\(matchText)).",
                            ].joined(separator: " ")
                } else {
                    self.openAIDashboardCookieImportStatus =
                        "Using \(sourceLabel) (\(result.cookieCount))."
                }
            }
            return effectiveEmail
        } catch let err as OpenAIDashboardBrowserCookieImporter.ImportError {
            switch err {
            case let .noMatchingAccount(found):
                let foundText: String = if found.isEmpty {
                    "no signed-in session detected in \(self.codexBrowserCookieOrder.loginHint)"
                } else {
                    found
                        .sorted { lhs, rhs in
                            if lhs.sourceLabel == rhs.sourceLabel { return lhs.email < rhs.email }
                            return lhs.sourceLabel < rhs.sourceLabel
                        }
                        .map { "\($0.sourceLabel): \($0.email)" }
                        .joined(separator: " • ")
                }
                self.logOpenAIWeb("[\(stamp)] import mismatch: \(foundText)")
                await MainActor.run {
                    self.openAIDashboardCookieImportStatus = allowAnyAccount
                        ? [
                            "No signed-in OpenAI web session found.",
                            "Found \(foundText).",
                        ].joined(separator: " ")
                        : Self.conciseOpenAICookieMismatchStatus(
                            found: found.map(\.email),
                            targetEmail: normalizedTarget)
                    self.failClosedOpenAIDashboardSnapshot()
                }
            case .noCookiesFound,
                 .browserAccessDenied,
                 .dashboardStillRequiresLogin,
                 .manualCookieHeaderInvalid:
                self.logOpenAIWeb("[\(stamp)] import failed: \(err.localizedDescription)")
                await MainActor.run {
                    self.openAIDashboardCookieImportStatus =
                        "OpenAI cookie import failed: \(err.localizedDescription)"
                    self.openAIDashboardRequiresLogin = true
                }
            }
        } catch {
            self.logOpenAIWeb("[\(stamp)] import failed: \(error.localizedDescription)")
            await MainActor.run {
                self.openAIDashboardCookieImportStatus =
                    "Browser cookie import failed: \(error.localizedDescription)"
            }
        }
        return nil
    }

    private func resetOpenAIWebDebugLog(context: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        self.openAIWebDebugLines.removeAll(keepingCapacity: true)
        self.openAIDashboardCookieImportDebugLog = nil
        self.logOpenAIWeb("[\(stamp)] OpenAI web \(context) start")
    }

    private func logOpenAIWeb(_ message: String) {
        let safeMessage = LogRedactor.redact(message)
        self.openAIWebLogger.debug(safeMessage)
        self.openAIWebDebugLines.append(safeMessage)
        if self.openAIWebDebugLines.count > 240 {
            self.openAIWebDebugLines.removeFirst(self.openAIWebDebugLines.count - 240)
        }
        self.openAIDashboardCookieImportDebugLog = self.openAIWebDebugLines.joined(separator: "\n")
    }

    func resetOpenAIWebState() {
        self.invalidateOpenAIDashboardRefreshTask()
        self.openAIDashboard = nil
        self.lastOpenAIDashboardError = nil
        self.lastOpenAIDashboardSnapshot = nil
        self.lastOpenAIDashboardTargetEmail = nil
        self.openAIDashboardRequiresLogin = false
        self.openAIDashboardCookieImportStatus = nil
        self.openAIDashboardCookieImportDebugLog = nil
        self.lastOpenAIDashboardCookieImportAttemptAt = nil
        self.lastOpenAIDashboardCookieImportEmail = nil
        self.lastKnownLiveSystemCodexEmail = nil
    }

    private func dashboardEmailMismatch(expected: String?, actual: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return false }
        guard let raw = actual?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        return raw.lowercased() != expected.lowercased()
    }

    private func openAIWebManagedTargetStoreIsUnreadable() -> Bool {
        guard case .managedAccount = self.settings.codexResolvedActiveSource else {
            return false
        }
        return self.settings.codexSettingsSnapshot(tokenOverride: nil).managedAccountStoreUnreadable
    }

    private func openAIWebManagedTargetIsMissing() -> Bool {
        guard case .managedAccount = self.settings.codexResolvedActiveSource else {
            return false
        }
        return self.selectedManagedCodexAccountForOpenAIWeb() == nil
    }

    private func selectedManagedCodexAccountForOpenAIWeb() -> ManagedCodexAccount? {
        guard case let .managedAccount(id) = self.settings.codexResolvedActiveSource else {
            return nil
        }

        let snapshot = self.settings.codexAccountReconciliationSnapshot
        return snapshot.storedAccounts.first { $0.id == id }
    }

    func codexAccountEmailForOpenAIDashboard(allowLastKnownLiveFallback: Bool = true) -> String? {
        switch self.settings.codexResolvedActiveSource {
        case .liveSystem:
            let liveSystem = self.settings.codexAccountReconciliationSnapshot.liveSystemAccount?.email
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let liveSystem, !liveSystem.isEmpty {
                self.lastKnownLiveSystemCodexEmail = liveSystem
                return liveSystem
            }

            guard allowLastKnownLiveFallback else { return nil }
            let lastKnown = self.lastKnownLiveSystemCodexEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastKnown, !lastKnown.isEmpty { return lastKnown }
            return nil
        case .managedAccount:
            if self.openAIWebManagedTargetStoreIsUnreadable() {
                return nil
            }

            let managed = self.selectedManagedCodexAccountForOpenAIWeb()?.email
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let managed, !managed.isEmpty { return managed }
            return nil
        }
    }

    func codexCookieCacheScopeForOpenAIWeb() -> CookieHeaderCache.Scope? {
        switch self.settings.codexResolvedActiveSource {
        case .liveSystem:
            nil
        case let .managedAccount(id):
            self.openAIWebManagedTargetStoreIsUnreadable() ? .managedStoreUnreadable : .managedAccount(id)
        }
    }
}

// MARK: - OpenAI web error messaging

extension UsageStore {
    func openAIDashboardFriendlyError(
        body: String,
        targetEmail: String?,
        cookieImportStatus: String?) -> String?
    {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = cookieImportStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [
                "OpenAI web dashboard returned an empty page.",
                "Sign in to chatgpt.com and update OpenAI cookies in Providers → Codex.",
            ].joined(separator: " ")
        }

        let lower = trimmed.lowercased()
        let looksLikePublicLanding = lower.contains("skip to content")
            && (lower.contains("about") || lower.contains("openai") || lower.contains("chatgpt"))
        let looksLoggedOut = lower.contains("sign in")
            || lower.contains("log in")
            || lower.contains("create account")
            || lower.contains("continue with google")
            || lower.contains("continue with apple")
            || lower.contains("continue with microsoft")

        guard looksLikePublicLanding || looksLoggedOut else { return nil }
        let emailLabel = targetEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLabel = (emailLabel?.isEmpty == false) ? emailLabel! : "your OpenAI account"
        if let status, !status.isEmpty {
            if status.contains("cookies do not match Codex account")
                || status.localizedCaseInsensitiveContains("openai cookies are for")
                || status.localizedCaseInsensitiveContains("cookie import failed")
            {
                return "\(status) Switch chatgpt.com account, then refresh OpenAI cookies."
            }
        }
        return [
            "OpenAI web dashboard returned a public page (not signed in).",
            "Sign in to chatgpt.com as \(targetLabel), then update OpenAI cookies in Providers → Codex.",
        ].joined(separator: " ")
    }

    private static func conciseOpenAICookieMismatchStatus(
        found: [String],
        targetEmail: String?)
        -> String
    {
        let normalizedFound = Array(Set(
            found
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }))
            .sorted()

        let foundLabel: String = switch normalizedFound.count {
        case 0:
            "another account"
        case 1:
            normalizedFound[0]
        case 2:
            "\(normalizedFound[0]) or \(normalizedFound[1])"
        default:
            "\(normalizedFound[0]) or \(normalizedFound.count - 1) other accounts"
        }

        let targetLabel = targetEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetLabel, !targetLabel.isEmpty else {
            return "OpenAI cookies are for \(foundLabel)."
        }
        return "OpenAI cookies are for \(foundLabel), not \(targetLabel)."
    }
}
