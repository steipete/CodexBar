import CodexBarCore
import Foundation

extension UsageStore {
    private enum CLIProxyMultiAuthRefreshState {
        case notHandled
        case success
        case failure(Error)
    }

    /// Force refresh Augment session (called from UI button)
    func forceRefreshAugmentSession() async {
        await self.performRuntimeAction(.forceSessionRefresh, for: .augment)
    }

    func refreshProvider(_ provider: UsageProvider, allowDisabled: Bool = false) async {
        guard let spec = self.providerSpecs[provider] else { return }

        if !spec.isEnabled(), !allowDisabled {
            self.refreshingProviders.remove(provider)
            await MainActor.run {
                self.snapshots.removeValue(forKey: provider)
                self.errors[provider] = nil
                self.lastSourceLabels.removeValue(forKey: provider)
                self.lastFetchAttempts.removeValue(forKey: provider)
                self.accountSnapshots.removeValue(forKey: provider)
                self.tokenSnapshots.removeValue(forKey: provider)
                self.tokenErrors[provider] = nil
                self.failureGates[provider]?.reset()
                self.tokenFailureGates[provider]?.reset()
                self.statuses.removeValue(forKey: provider)
                self.lastKnownSessionRemaining.removeValue(forKey: provider)
                self.lastTokenFetchAt.removeValue(forKey: provider)
            }
            return
        }

        self.refreshingProviders.insert(provider)
        defer { self.refreshingProviders.remove(provider) }

        let tokenAccounts = self.tokenAccounts(for: provider)
        let shouldFetchAllTokenAccounts = self.shouldFetchAllTokenAccounts(provider: provider, accounts: tokenAccounts)
        if shouldFetchAllTokenAccounts {
            await self.refreshTokenAccounts(provider: provider, accounts: tokenAccounts)
            return
        }

        let cliProxyMultiAuthState = await self.refreshCLIProxyMultiAuthIfNeeded(provider: provider)
        switch cliProxyMultiAuthState {
        case .notHandled:
            break
        case .success:
            if let runtime = self.providerRuntimes[provider] {
                let context = ProviderRuntimeContext(provider: provider, settings: self.settings, store: self)
                runtime.providerDidRefresh(context: context, provider: provider)
            }
            return
        case let .failure(error):
            if let runtime = self.providerRuntimes[provider] {
                let context = ProviderRuntimeContext(provider: provider, settings: self.settings, store: self)
                runtime.providerDidFail(context: context, provider: provider, error: error)
            }
            return
        }

        let outcome = await spec.fetch()
        if provider == .claude,
           ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
        {
            await MainActor.run {
                self.snapshots.removeValue(forKey: .claude)
                self.errors[.claude] = nil
                self.lastSourceLabels.removeValue(forKey: .claude)
                self.lastFetchAttempts.removeValue(forKey: .claude)
                self.accountSnapshots.removeValue(forKey: .claude)
                self.tokenSnapshots.removeValue(forKey: .claude)
                self.tokenErrors[.claude] = nil
                self.failureGates[.claude]?.reset()
                self.tokenFailureGates[.claude]?.reset()
                self.lastTokenFetchAt.removeValue(forKey: .claude)
            }
        }
        await MainActor.run {
            self.lastFetchAttempts[provider] = outcome.attempts
        }

        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            await MainActor.run {
                self.handleSessionQuotaTransition(provider: provider, snapshot: scoped)
                self.snapshots[provider] = scoped
                self.lastSourceLabels[provider] = result.sourceLabel
                if !shouldFetchAllTokenAccounts {
                    self.accountSnapshots.removeValue(forKey: provider)
                }
                if provider == .codex {
                    self.credits = result.credits
                    self.lastCreditsError = nil
                }
                self.errors[provider] = nil
                self.failureGates[provider]?.recordSuccess()
            }
            if let runtime = self.providerRuntimes[provider] {
                let context = ProviderRuntimeContext(
                    provider: provider, settings: self.settings, store: self)
                runtime.providerDidRefresh(context: context, provider: provider)
            }
        case let .failure(error):
            await MainActor.run {
                let hadPriorData = self.snapshots[provider] != nil
                let shouldSurface =
                    self.failureGates[provider]?
                        .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
                if !shouldFetchAllTokenAccounts {
                    self.accountSnapshots.removeValue(forKey: provider)
                }
                if shouldSurface {
                    self.errors[provider] = error.localizedDescription
                    self.snapshots.removeValue(forKey: provider)
                } else {
                    self.errors[provider] = nil
                }
            }
            if let runtime = self.providerRuntimes[provider] {
                let context = ProviderRuntimeContext(
                    provider: provider, settings: self.settings, store: self)
                runtime.providerDidFail(context: context, provider: provider, error: error)
            }
        }
    }

    private func refreshCLIProxyMultiAuthIfNeeded(provider: UsageProvider) async -> CLIProxyMultiAuthRefreshState {
        guard self.supportsCLIProxyMultiAuth(provider: provider) else { return .notHandled }
        if provider == .codex, self.sourceMode(for: .codex) != .api {
            return .notHandled
        }

        let settingsSnapshot = ProviderRegistry.makeSettingsSnapshot(settings: self.settings, tokenOverride: nil)
        let env = ProviderRegistry.makeEnvironment(
            base: ProcessInfo.processInfo.environment,
            provider: provider,
            settings: self.settings,
            tokenOverride: nil)

        guard let proxySettings = CodexCLIProxySettings.resolve(
            providerSettings: settingsSnapshot.codex,
            environment: env)
        else {
            return .notHandled
        }

        guard proxySettings.authIndex == nil else { return .notHandled }

        let client = CodexCLIProxyManagementClient(settings: proxySettings)
        let auths: [CodexCLIProxyResolvedAuth]
        do {
            auths = try await self.listCLIProxyAuths(provider: provider, client: client)
        } catch {
            return .notHandled
        }

        guard auths.count > 1 else { return .notHandled }

        var accountSnapshots: [TokenAccountUsageSnapshot] = []
        accountSnapshots.reserveCapacity(auths.count)

        var successfulUsageSnapshots: [UsageSnapshot] = []
        successfulUsageSnapshots.reserveCapacity(auths.count)

        var creditBalances: [Double] = []
        creditBalances.reserveCapacity(auths.count)

        var firstError: Error?
        for auth in auths {
            let account = self.codexCLIProxyAccount(for: auth)
            do {
                let fetchResult = try await self.cliProxyFetchResult(provider: provider, auth: auth, client: client)
                let mapped = fetchResult.snapshot
                let labeled = self.applyAccountLabel(mapped, provider: provider, account: account)
                successfulUsageSnapshots.append(labeled)
                if let credits = fetchResult.credits {
                    creditBalances.append(credits.remaining)
                }
                accountSnapshots.append(TokenAccountUsageSnapshot(
                    account: account,
                    snapshot: labeled,
                    error: nil,
                    sourceLabel: "cliproxy-api"))
            } catch {
                if firstError == nil { firstError = error }
                accountSnapshots.append(TokenAccountUsageSnapshot(
                    account: account,
                    snapshot: nil,
                    error: error.localizedDescription,
                    sourceLabel: "cliproxy-api"))
            }
        }

        let aggregatedCredits: CreditsSnapshot? = if creditBalances.isEmpty {
            nil
        } else {
            CreditsSnapshot(remaining: creditBalances.reduce(0, +), events: [], updatedAt: Date())
        }

        if let aggregate = self.aggregateCodexCLIProxySnapshot(
            successfulUsageSnapshots,
            provider: provider,
            totalAuthCount: auths.count)
        {
            await MainActor.run {
                self.handleSessionQuotaTransition(provider: provider, snapshot: aggregate)
                self.snapshots[provider] = aggregate
                self.accountSnapshots[provider] = accountSnapshots
                self.lastSourceLabels[provider] = "cliproxy-api"
                self.lastFetchAttempts[provider] = []
                self.errors[provider] = nil
                if provider == .codex {
                    self.credits = aggregatedCredits
                    self.lastCreditsError = nil
                }
                self.failureGates[provider]?.recordSuccess()
            }
            return .success
        }

        let resolvedError = firstError ?? self.cliProxyMissingAuthError(for: provider, authIndex: nil)
        await MainActor.run {
            self.snapshots.removeValue(forKey: provider)
            self.accountSnapshots[provider] = accountSnapshots
            self.lastSourceLabels[provider] = "cliproxy-api"
            self.lastFetchAttempts[provider] = []
            self.errors[provider] = resolvedError.localizedDescription
            if provider == .codex {
                self.credits = nil
                self.lastCreditsError = nil
            }
        }
        return .failure(resolvedError)
    }

    private func supportsCLIProxyMultiAuth(provider: UsageProvider) -> Bool {
        provider == .codex || provider == .codexproxy || provider == .geminiproxy || provider == .antigravityproxy
    }

    private func listCLIProxyAuths(
        provider: UsageProvider,
        client: CodexCLIProxyManagementClient) async throws -> [CodexCLIProxyResolvedAuth]
    {
        switch provider {
        case .codex, .codexproxy:
            return try await client.listCodexAuths()
        case .geminiproxy:
            return try await client.listGeminiAuths()
        case .antigravityproxy:
            return try await client.listAntigravityAuths()
        default:
            return []
        }
    }

    private func cliProxyMissingAuthError(for provider: UsageProvider, authIndex: String?) -> CodexCLIProxyError {
        switch provider {
        case .codex, .codexproxy:
            return .missingCodexAuth(authIndex)
        case .geminiproxy:
            return .missingProviderAuth(provider: "Gemini", authIndex: authIndex)
        case .antigravityproxy:
            return .missingProviderAuth(provider: "Antigravity", authIndex: authIndex)
        default:
            return .missingCodexAuth(authIndex)
        }
    }

    private func cliProxyFetchResult(
        provider: UsageProvider,
        auth: CodexCLIProxyResolvedAuth,
        client: CodexCLIProxyManagementClient) async throws -> (snapshot: UsageSnapshot, credits: CreditsSnapshot?)
    {
        switch provider {
        case .codex, .codexproxy:
            let usage = try await client.fetchCodexUsage(auth: auth)
            return (
                snapshot: self.codexUsageSnapshot(from: usage, auth: auth, provider: provider),
                credits: provider == .codex ? self.codexCreditsSnapshot(from: usage) : nil
            )
        case .geminiproxy:
            let quota = try await client.fetchGeminiQuota(auth: auth)
            return (
                snapshot: CLIProxyGeminiQuotaSnapshotMapper.usageSnapshot(
                    from: quota,
                    auth: auth,
                    provider: .geminiproxy),
                credits: nil
            )
        case .antigravityproxy:
            let quota = try await client.fetchAntigravityQuota(auth: auth)
            return (
                snapshot: CLIProxyGeminiQuotaSnapshotMapper.usageSnapshot(
                    from: quota,
                    auth: auth,
                    provider: .antigravityproxy),
                credits: nil
            )
        default:
            throw self.cliProxyMissingAuthError(for: provider, authIndex: auth.authIndex)
        }
    }

    private func codexCLIProxyAccount(for auth: CodexCLIProxyResolvedAuth) -> ProviderTokenAccount {
        ProviderTokenAccount(
            id: UUID(),
            label: self.codexCLIProxyAccountLabel(auth),
            token: "",
            addedAt: 0,
            lastUsed: nil)
    }

    private func codexCLIProxyAccountLabel(_ auth: CodexCLIProxyResolvedAuth) -> String {
        if let email = auth.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        return auth.authIndex
    }

    private func aggregateCodexCLIProxySnapshot(
        _ snapshots: [UsageSnapshot],
        provider: UsageProvider,
        totalAuthCount: Int) -> UsageSnapshot?
    {
        guard !snapshots.isEmpty else { return nil }

        let primary = self.aggregateWindow(snapshots.compactMap(\.primary))
        let secondary = self.aggregateWindow(snapshots.compactMap(\.secondary))
        let tertiary = self.aggregateWindow(snapshots.compactMap(\.tertiary))

        let loginMethods = Set(
            snapshots.compactMap { snapshot in
                snapshot.loginMethod(for: provider)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        let loginMethod = loginMethods.count == 1 ? loginMethods.first : nil

        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let accountLabelFormat = L10n.tr(
            "provider.cliproxy.aggregate.account_label",
            fallback: "All %@ auth entries (%d)")
        let accountLabel = String(format: accountLabelFormat, locale: .current, providerName, totalAuthCount)
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: accountLabel,
            accountOrganization: nil,
            loginMethod: loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: Date(),
            identity: identity)
    }

    private func aggregateWindow(_ windows: [RateWindow]) -> RateWindow? {
        guard !windows.isEmpty else { return nil }
        let usedPercent = windows.map(\.usedPercent).reduce(0, +) / Double(windows.count)
        let windowMinutes = windows.compactMap(\.windowMinutes).max()
        let resetsAt = windows.compactMap(\.resetsAt).min()
        let resetDescription = resetsAt.map { UsageFormatter.resetDescription(from: $0) }
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription)
    }

    private func codexUsageSnapshot(
        from usage: CodexUsageResponse,
        auth: CodexCLIProxyResolvedAuth,
        provider: UsageProvider) -> UsageSnapshot
    {
        let primary = self.codexRateWindow(from: usage.rateLimit?.primaryWindow)
            ?? RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = self.codexRateWindow(from: usage.rateLimit?.secondaryWindow)
        let resolvedPlan = usage.planType?.rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPlan = auth.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (resolvedPlan?.isEmpty == false) ? resolvedPlan : fallbackPlan
        let normalizedEmail = auth.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: normalizedEmail?.isEmpty == true ? nil : normalizedEmail,
            accountOrganization: nil,
            loginMethod: loginMethod?.isEmpty == true ? nil : loginMethod)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)
            .scoped(to: provider)
    }

    private func codexRateWindow(from window: CodexUsageResponse.WindowSnapshot?) -> RateWindow? {
        guard let window else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        return RateWindow(
            usedPercent: Double(window.usedPercent),
            windowMinutes: window.limitWindowSeconds / 60,
            resetsAt: resetDate,
            resetDescription: UsageFormatter.resetDescription(from: resetDate))
    }

    private func codexCreditsSnapshot(from usage: CodexUsageResponse) -> CreditsSnapshot? {
        guard let credits = usage.credits, credits.hasCredits, let balance = credits.balance else { return nil }
        return CreditsSnapshot(remaining: balance, events: [], updatedAt: Date())
    }
}
