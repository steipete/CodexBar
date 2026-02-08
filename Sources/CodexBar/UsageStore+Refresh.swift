import CodexBarCore
import Foundation

extension UsageStore {
    private enum CodexCLIProxyMultiAuthRefreshState {
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
        if self.shouldFetchAllTokenAccounts(provider: provider, accounts: tokenAccounts) {
            await self.refreshTokenAccounts(provider: provider, accounts: tokenAccounts)
            return
        } else {
            _ = await MainActor.run {
                self.accountSnapshots.removeValue(forKey: provider)
            }
        }

        let codexCLIProxyMultiAuthState = await self.refreshCodexCLIProxyMultiAuthIfNeeded(provider: provider)
        switch codexCLIProxyMultiAuthState {
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

    private func refreshCodexCLIProxyMultiAuthIfNeeded(provider: UsageProvider) async -> CodexCLIProxyMultiAuthRefreshState {
        guard provider == .codex else { return .notHandled }
        guard self.sourceMode(for: .codex) == .api else { return .notHandled }

        let settingsSnapshot = ProviderRegistry.makeSettingsSnapshot(settings: self.settings, tokenOverride: nil)
        let env = ProviderRegistry.makeEnvironment(
            base: ProcessInfo.processInfo.environment,
            provider: .codex,
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
            auths = try await client.listCodexAuths()
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
                let usage = try await client.fetchCodexUsage(auth: auth)
                let mapped = self.codexUsageSnapshot(from: usage, auth: auth)
                let labeled = self.applyAccountLabel(mapped, provider: .codex, account: account)
                successfulUsageSnapshots.append(labeled)
                if let credits = self.codexCreditsSnapshot(from: usage) {
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
            totalAuthCount: auths.count)
        {
            await MainActor.run {
                self.handleSessionQuotaTransition(provider: .codex, snapshot: aggregate)
                self.snapshots[.codex] = aggregate
                self.accountSnapshots[.codex] = accountSnapshots
                self.lastSourceLabels[.codex] = "cliproxy-api"
                self.lastFetchAttempts[.codex] = []
                self.errors[.codex] = nil
                self.credits = aggregatedCredits
                self.lastCreditsError = nil
                self.failureGates[.codex]?.recordSuccess()
            }
            return .success
        }

        let resolvedError = firstError ?? CodexCLIProxyError.missingCodexAuth(nil)
        await MainActor.run {
            self.snapshots.removeValue(forKey: .codex)
            self.accountSnapshots[.codex] = accountSnapshots
            self.lastSourceLabels[.codex] = "cliproxy-api"
            self.lastFetchAttempts[.codex] = []
            self.errors[.codex] = resolvedError.localizedDescription
            self.credits = nil
            self.lastCreditsError = nil
        }
        return .failure(resolvedError)
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
        totalAuthCount: Int) -> UsageSnapshot?
    {
        guard !snapshots.isEmpty else { return nil }

        let primary = self.aggregateWindow(snapshots.compactMap(\.primary))
        let secondary = self.aggregateWindow(snapshots.compactMap(\.secondary))
        let tertiary = self.aggregateWindow(snapshots.compactMap(\.tertiary))

        let loginMethods = Set(
            snapshots.compactMap { snapshot in
                snapshot.loginMethod(for: .codex)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        let loginMethod = loginMethods.count == 1 ? loginMethods.first : nil

        let accountLabelFormat = L10n.tr(
            "provider.codex.cliproxy.aggregate.account_label",
            fallback: "All Codex auth entries (%d)")
        let accountLabel = String(format: accountLabelFormat, locale: .current, totalAuthCount)
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
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

    private func codexUsageSnapshot(from usage: CodexUsageResponse, auth: CodexCLIProxyResolvedAuth) -> UsageSnapshot {
        let primary = self.codexRateWindow(from: usage.rateLimit?.primaryWindow)
            ?? RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = self.codexRateWindow(from: usage.rateLimit?.secondaryWindow)
        let resolvedPlan = usage.planType?.rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPlan = auth.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (resolvedPlan?.isEmpty == false) ? resolvedPlan : fallbackPlan
        let normalizedEmail = auth.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: normalizedEmail?.isEmpty == true ? nil : normalizedEmail,
            accountOrganization: nil,
            loginMethod: loginMethod?.isEmpty == true ? nil : loginMethod)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)
            .scoped(to: .codex)
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
