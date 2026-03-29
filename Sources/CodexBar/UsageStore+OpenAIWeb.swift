import CodexBarCore
import Foundation

// MARK: - OpenAI web lifecycle

extension UsageStore {
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
        Task { await self.refreshOpenAIDashboardIfNeeded(force: true) }
    }

    func applyOpenAIDashboard(_ dash: OpenAIDashboardSnapshot, targetEmail: String?) async {
        await MainActor.run {
            self.openAIDashboard = dash
            self.lastOpenAIDashboardError = nil
            self.lastOpenAIDashboardSnapshot = dash
            self.openAIDashboardRequiresLogin = false
            // Only fill gaps; OAuth/CLI remain the primary sources for usage + credits.
            if self.snapshots[.codex] == nil,
               let usage = dash.toUsageSnapshot(provider: .codex, accountEmail: targetEmail)
            {
                self.snapshots[.codex] = usage
                self.errors[.codex] = nil
                self.failureGates[.codex]?.recordSuccess()
                self.lastSourceLabels[.codex] = "openai-web"
            }
            if self.credits == nil, let credits = dash.toCreditsSnapshot() {
                self.credits = credits
                self.lastCreditsSnapshot = credits
                self.lastCreditsError = nil
                self.creditsFailureStreak = 0
            }
        }

        if let email = targetEmail, !email.isEmpty {
            OpenAIDashboardCacheStore.save(OpenAIDashboardCache(accountEmail: email, snapshot: dash))
        }
        self.backfillCodexHistoricalFromDashboardIfNeeded(dash)
    }

    func applyOpenAIDashboardFailure(message: String) async {
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

    func applyOpenAIDashboardMismatchFailure(signedInEmail: String, expectedEmail: String?) async {
        await MainActor.run {
            self.failClosedOpenAIDashboardSnapshot()
            self.lastOpenAIDashboardError = [
                "OpenAI dashboard signed in as \(signedInEmail), but Codex uses \(expectedEmail ?? "unknown").",
                "Switch accounts in your browser and update OpenAI cookies in Providers → Codex.",
            ].joined(separator: " ")
        }
    }

    func applyOpenAIDashboardLoginRequiredFailure() async {
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

    func refreshOpenAIDashboardIfNeeded(force: Bool = false) async {
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

        let targetEmail = self.codexAccountEmailForOpenAIDashboard()
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
            let normalized = targetEmail?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var effectiveEmail = targetEmail

            // Use a per-email persistent `WKWebsiteDataStore` so multiple dashboard sessions can coexist.
            // Strategy:
            // - Try the existing per-email WebKit cookie store first (fast; avoids Keychain prompts).
            // - On login-required or account mismatch, import cookies from the configured browser order and retry once.
            if self.openAIWebAccountDidChange, let targetEmail, !targetEmail.isEmpty {
                // On account switches, proactively re-import cookies so we don't show stale data from the previous
                // user.
                if let imported = await self.importOpenAIDashboardCookiesIfNeeded(
                    targetEmail: targetEmail,
                    force: true)
                {
                    effectiveEmail = imported
                }
                self.openAIWebAccountDidChange = false
            }

            var dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
                accountEmail: effectiveEmail,
                logger: log,
                debugDumpHTML: false,
                timeout: Self.openAIWebPrimaryFetchTimeout)

            if self.dashboardEmailMismatch(expected: normalized, actual: dash.signedInEmail) {
                if let imported = await self.importOpenAIDashboardCookiesIfNeeded(
                    targetEmail: targetEmail,
                    force: true)
                {
                    effectiveEmail = imported
                }
                dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
                    accountEmail: effectiveEmail,
                    logger: log,
                    debugDumpHTML: false,
                    timeout: Self.openAIWebRetryFetchTimeout)
            }

            if self.dashboardEmailMismatch(expected: normalized, actual: dash.signedInEmail) {
                let signedIn = dash.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                await self.applyOpenAIDashboardMismatchFailure(signedInEmail: signedIn, expectedEmail: normalized)
                return
            }

            await self.applyOpenAIDashboard(dash, targetEmail: effectiveEmail)
        } catch let OpenAIDashboardFetcher.FetchError.noDashboardData(body) {
            // Often indicates a missing/stale session without an obvious login prompt. Retry once after
            // importing cookies from the user's browser.
            let targetEmail = self.codexAccountEmailForOpenAIDashboard()
            var effectiveEmail = targetEmail
            if let imported = await self.importOpenAIDashboardCookiesIfNeeded(targetEmail: targetEmail, force: true) {
                effectiveEmail = imported
            }
            do {
                let dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
                    accountEmail: effectiveEmail,
                    logger: log,
                    debugDumpHTML: true,
                    timeout: Self.openAIWebRetryFetchTimeout)
                await self.applyOpenAIDashboard(dash, targetEmail: effectiveEmail)
            } catch let OpenAIDashboardFetcher.FetchError.noDashboardData(retryBody) {
                let finalBody = retryBody.isEmpty ? body : retryBody
                let message = self.openAIDashboardFriendlyError(
                    body: finalBody,
                    targetEmail: targetEmail,
                    cookieImportStatus: self.openAIDashboardCookieImportStatus)
                    ?? OpenAIDashboardFetcher.FetchError.noDashboardData(body: finalBody).localizedDescription
                await self.applyOpenAIDashboardFailure(message: message)
            } catch {
                await self.applyOpenAIDashboardFailure(message: error.localizedDescription)
            }
        } catch OpenAIDashboardFetcher.FetchError.loginRequired {
            let targetEmail = self.codexAccountEmailForOpenAIDashboard()
            var effectiveEmail = targetEmail
            if let imported = await self.importOpenAIDashboardCookiesIfNeeded(targetEmail: targetEmail, force: true) {
                effectiveEmail = imported
            }
            do {
                let dash = try await OpenAIDashboardFetcher().loadLatestDashboard(
                    accountEmail: effectiveEmail,
                    logger: log,
                    debugDumpHTML: true,
                    timeout: Self.openAIWebRetryFetchTimeout)
                await self.applyOpenAIDashboard(dash, targetEmail: effectiveEmail)
            } catch OpenAIDashboardFetcher.FetchError.loginRequired {
                await self.applyOpenAIDashboardLoginRequiredFailure()
            } catch {
                await self.applyOpenAIDashboardFailure(message: error.localizedDescription)
            }
        } catch {
            await self.applyOpenAIDashboardFailure(message: error.localizedDescription)
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
        let targetEmail = self.codexAccountEmailForOpenAIDashboard()
        _ = await self.importOpenAIDashboardCookiesIfNeeded(targetEmail: targetEmail, force: true)
        await self.refreshOpenAIDashboardIfNeeded(force: true)
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
                        : [
                            "Browser cookies do not match Codex account (\(normalizedTarget ?? "unknown")).",
                            "Found \(foundText).",
                        ].joined(separator: " ")
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
        self.openAIDashboard = nil
        self.lastOpenAIDashboardError = nil
        self.lastOpenAIDashboardSnapshot = nil
        self.lastOpenAIDashboardTargetEmail = nil
        self.openAIDashboardRequiresLogin = false
        self.openAIDashboardCookieImportStatus = nil
        self.openAIDashboardCookieImportDebugLog = nil
        self.lastOpenAIDashboardCookieImportAttemptAt = nil
        self.lastOpenAIDashboardCookieImportEmail = nil
    }

    private func dashboardEmailMismatch(expected: String?, actual: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return false }
        guard let raw = actual?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        return raw.lowercased() != expected.lowercased()
    }

    private func openAIWebManagedTargetStoreIsUnreadable() -> Bool {
        guard case .managedAccount = self.settings.codexActiveSource else {
            return false
        }
        return self.settings.hasUnreadableManagedCodexAccountStore
    }

    private func openAIWebManagedTargetIsMissing() -> Bool {
        guard case .managedAccount = self.settings.codexActiveSource else {
            return false
        }
        return self.selectedManagedCodexAccountForOpenAIWeb() == nil
    }

    private func selectedManagedCodexAccountForOpenAIWeb() -> ManagedCodexAccount? {
        guard case let .managedAccount(id) = self.settings.codexActiveSource else {
            return nil
        }

        let snapshot = self.settings.codexAccountReconciliationSnapshot
        return snapshot.storedAccounts.first { $0.id == id }
    }

    func codexAccountEmailForOpenAIDashboard() -> String? {
        switch self.settings.codexActiveSource {
        case .liveSystem:
            let liveSystem = self.settings.codexAccountReconciliationSnapshot.liveSystemAccount?.email
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let liveSystem, !liveSystem.isEmpty { return liveSystem }

            let direct = self.snapshots[.codex]?.accountEmail(for: .codex)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let direct, !direct.isEmpty { return direct }
            let fallback = self.codexFetcher.loadAccountInfo().email?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fallback, !fallback.isEmpty { return fallback }
        case .managedAccount:
            if self.openAIWebManagedTargetStoreIsUnreadable() {
                return nil
            }

            let managed = self.selectedManagedCodexAccountForOpenAIWeb()?.email
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let managed, !managed.isEmpty { return managed }
            return nil
        }

        let cached = self.openAIDashboard?.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached, !cached.isEmpty { return cached }
        let imported = self.lastOpenAIDashboardCookieImportEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let imported, !imported.isEmpty { return imported }
        return nil
    }

    func codexCookieCacheScopeForOpenAIWeb() -> CookieHeaderCache.Scope? {
        switch self.settings.codexActiveSource {
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
                || status.localizedCaseInsensitiveContains("cookie import failed")
            {
                return [
                    status,
                    "Sign in to chatgpt.com as \(targetLabel), then update OpenAI cookies in Providers → Codex.",
                ].joined(separator: " ")
            }
        }
        return [
            "OpenAI web dashboard returned a public page (not signed in).",
            "Sign in to chatgpt.com as \(targetLabel), then update OpenAI cookies in Providers → Codex.",
        ].joined(separator: " ")
    }
}
