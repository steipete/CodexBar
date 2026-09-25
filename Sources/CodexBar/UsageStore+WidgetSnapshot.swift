import CodexBarCore
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

extension UsageStore {
    /// Tests must never touch the real app-group container: the widget-snapshot
    /// `open()` can block forever behind macOS 26 app-data (TCC) gating, hanging
    /// the whole suite. A test opts into persistence with an in-memory save
    /// override (its container load is stubbed out) or an injected snapshot URL
    /// that redirects all I/O to a test-owned file.
    static func shouldPersistWidgetSnapshot(
        isRunningTests: Bool,
        hasSaveOverride: Bool,
        hasInjectedSnapshotURL: Bool) -> Bool
    {
        !isRunningTests || hasSaveOverride || hasInjectedSnapshotURL
    }

    func persistWidgetSnapshot(reason: String) {
        guard Self.shouldPersistWidgetSnapshot(
            isRunningTests: SettingsStore.isRunningTests,
            hasSaveOverride: self._test_widgetSnapshotSaveOverride != nil,
            hasInjectedSnapshotURL: self.widgetSnapshotURL != nil)
        else { return }
        // A fresh process has token-cost data before a user-authorized Claude OAuth refresh can run.
        // Keep the last queued snapshot in memory so back-to-back writes cannot race the on-disk cache.
        let previousSnapshot = self.lastQueuedWidgetSnapshot ?? {
            #if DEBUG
            // Snapshot-save overrides must stay isolated from a developer's real app-group data.
            guard self._test_widgetSnapshotSaveOverride == nil else { return nil }
            #endif
            if let widgetSnapshotURL = self.widgetSnapshotURL {
                return WidgetSnapshotStore.load(from: widgetSnapshotURL)
            }
            return WidgetSnapshotStore.load()
        }()
        let snapshot = self.makeWidgetSnapshot(previousSnapshot: previousSnapshot)
        self.lastQueuedWidgetSnapshot = snapshot
        self.lastQueuedWidgetSnapshotIsPreservable = snapshot.entries.allSatisfy {
            !self.widgetUsagePreservationBlockedProviders.contains($0.provider)
        }
        NotificationCenter.default.post(
            name: .codexbarUsageSnapshotsDidChange,
            object: UsageSnapshotsDidChangeEvent(snapshots: self.cloudSyncAccountSnapshots()))
        let previousTask = self.widgetSnapshotPersistTask
        self.widgetSnapshotPersistTask = Task { @MainActor in
            _ = await previousTask?.result

            if let override = self._test_widgetSnapshotSaveOverride {
                await override(snapshot)
                return
            }

            await Self.saveWidgetSnapshot(
                snapshot,
                to: self.widgetSnapshotURL,
                isRunningTests: SettingsStore.isRunningTests,
                reloadTimelines: self.widgetTimelineReloader)
        }
    }

    static func saveWidgetSnapshot(
        _ snapshot: WidgetSnapshot,
        to url: URL?,
        isRunningTests: Bool,
        reloadTimelines: @MainActor () -> Void) async
    {
        await Task.detached(priority: .utility) {
            if let url {
                WidgetSnapshotStore.save(snapshot, to: url)
            } else {
                WidgetSnapshotStore.save(snapshot)
            }
        }.value
        // Opting into file persistence in tests never opts into WidgetKit side effects.
        guard !isRunningTests else { return }
        reloadTimelines()
    }

    static func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Builds outbound snapshots only from this Mac's UsageStore; remote fleet snapshots live in CloudSyncState.
    func cloudSyncAccountSnapshots() -> [AccountSnapshotSyncPayload] {
        let deviceID = self.settings.iCloudSyncDeviceID
        var payloads: [String: AccountSnapshotSyncPayload] = [:]

        for (instanceID, usage) in self.snapshots {
            let identity = usage.identity?.accountID ?? usage.identity?.accountEmail
            let label = usage.identity?.accountEmail
                ?? usage.identity?.accountOrganization
                ?? instanceID.firstPartyProvider
                .map { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }
                ?? instanceID.rawValue
            let payload = AccountSnapshotSyncPayload(
                provider: instanceID,
                deviceID: deviceID,
                accountIdentity: identity,
                displayLabel: label,
                usage: usage)
            payloads[payload.recordName] = payload
        }

        for (provider, accountSnapshots) in self.accountSnapshots {
            for accountSnapshot in accountSnapshots {
                guard let usage = accountSnapshot.snapshot else { continue }
                let identity = usage.identity?.accountID
                    ?? usage.identity?.accountEmail
                    ?? accountSnapshot.account.externalIdentifier
                    ?? accountSnapshot.account.id.uuidString
                let payload = AccountSnapshotSyncPayload(
                    provider: provider,
                    deviceID: deviceID,
                    accountIdentity: identity,
                    displayLabel: accountSnapshot.account.displayName,
                    usage: usage)
                payloads[payload.recordName] = payload
            }
        }

        for accountSnapshot in self.claudeSwapAccountSnapshots {
            guard let usage = accountSnapshot.snapshot else { continue }
            let identity = usage.identity?.accountID
                ?? usage.identity?.accountEmail
                ?? "\(accountSnapshot.id.source):\(accountSnapshot.id.opaqueID)"
            let payload = AccountSnapshotSyncPayload(
                provider: accountSnapshot.provider.instanceID,
                deviceID: deviceID,
                accountIdentity: identity,
                displayLabel: accountSnapshot.accountEmail ?? "Account \(accountSnapshot.id.opaqueID)",
                usage: usage)
            payloads[payload.recordName] = payload
        }

        return payloads.values.sorted { $0.recordName < $1.recordName }
    }

    func cloudSyncLocalAccountKeys(for provider: UsageProvider) -> Set<String> {
        let snapshotKeys = self.cloudSyncAccountSnapshots().filter { $0.provider == provider.instanceID }
            .map(\.accountKey)
        var identities = Set(snapshotKeys)
        var hasDefaultCodexSnapshot = false
        func insert(_ identity: String?) {
            guard let identity else { return }
            identities.insert(AccountSnapshotSyncPayload.accountKey(for: identity))
        }
        for accountSnapshot in self.accountSnapshots[provider.instanceID] ?? [] {
            insert(accountSnapshot.snapshot?.identity?.accountID)
            insert(accountSnapshot.snapshot?.identity?.accountEmail)
            insert(accountSnapshot.account.externalIdentifier)
            insert(accountSnapshot.account.id.uuidString)
        }
        for account in self.settings.tokenAccounts(for: provider) {
            insert(account.externalIdentifier)
            insert(account.id.uuidString)
        }
        // Provider-specific by design: Claude swap subprocesses own extra IDs; Codex alone has scoped account info.
        if provider == .claude {
            for accountSnapshot in self.claudeSwapAccountSnapshots {
                insert(accountSnapshot.snapshot?.identity?.accountID)
                insert(accountSnapshot.snapshot?.identity?.accountEmail)
                insert("\(accountSnapshot.id.source):\(accountSnapshot.id.opaqueID)")
            }
        }
        if provider == .codex {
            if let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay {
                for account in projection.visibleAccounts {
                    insert(account.workspaceAccountID)
                    insert(account.email)
                    insert(account.id)
                    insert(account.storedAccountID?.uuidString)
                }
            }
            hasDefaultCodexSnapshot = snapshotKeys.contains(AccountSnapshotSyncPayload.accountKey(for: nil))
        }
        if identities.isEmpty || hasDefaultCodexSnapshot {
            let fallback = self.accountInfo(for: provider)
            insert(fallback.email)
        }
        return identities
    }

    func invalidateGenericWidgetUsage(for provider: UsageProvider) {
        // Provider-specific by design: Claude keeps its existing owner-aware preservation policy.
        guard provider != .claude else { return }
        self.widgetUsagePreservationBlockedProviders.insert(provider.instanceID)
        // A successful fetch cannot make an older queued account valid again.
        if self.lastQueuedWidgetSnapshot?.entries.contains(where: { $0.provider == provider.instanceID }) == true {
            self.lastQueuedWidgetSnapshotIsPreservable = false
        }
    }

    private func makeWidgetSnapshot(previousSnapshot: WidgetSnapshot?) -> WidgetSnapshot {
        let now = Date()
        let enabledProviders = self.enabledProviders()
        var entries = UsageProvider.allCases.compactMap { provider in
            self.makeWidgetEntry(
                for: provider,
                now: now,
                previousEntry: previousSnapshot?.entries.first { $0.provider == provider.instanceID })
        }
        // Only reuse this process's publication; disk entries do not establish the current account's ownership.
        if entries.isEmpty, self.lastQueuedWidgetSnapshotIsPreservable,
           let previousSnapshot = self.lastQueuedWidgetSnapshot,
           previousSnapshot.enabledProviders.allSatisfy(enabledProviders.contains),
           previousSnapshot.entries.allSatisfy({ entry in
               // Provider-specific by design: Claude's owner-aware preservation above remains authoritative.
               entry.provider != .claude && enabledProviders.contains(entry.provider) &&
                   self.errors[entry.provider] != nil &&
                   (entry.providerCost == nil || self.settings.showOptionalCreditsAndExtraUsage) &&
                   !self.widgetUsagePreservationBlockedProviders.contains(entry.provider)
           })
        {
            entries = previousSnapshot.entries
        }
        return WidgetSnapshot(
            entries: entries,
            accounts: self.makeWidgetAccountEntries(now: now),
            enabledProviders: enabledProviders,
            usageBarsShowUsed: self.settings.usageBarsShowUsed,
            generatedAt: now)
    }

    private func makeWidgetEntry(
        for provider: UsageProvider,
        now: Date,
        previousEntry: WidgetSnapshot.ProviderEntry?) -> WidgetSnapshot.ProviderEntry?
    {
        // The ambient probe can still hold another account's quota while claude-swap owns the menu.
        let swapOwnsClaude = self.settings.claudeSwapEnabled && ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: provider,
            accountCount: self.claudeSwapAccountSnapshots.count,
            showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        let activeSwapAccount = swapOwnsClaude ? self.claudeSwapAccountSnapshots.first(where: \.isActive) : nil
        let snapshot = swapOwnsClaude ? activeSwapAccount?.snapshot : self.snapshots[provider.instanceID]
        let tokenSnapshot = self.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot
        let claudeQuotaOwnerKey: String? = if swapOwnsClaude {
            activeSwapAccount.flatMap { account in
                ClaudeSwapRetainedUsageStore.ownershipFingerprint(for: account)
                    .map { "claude/swap:\(account.id.opaqueID):\($0)" }
            }
        } else if provider == .claude {
            self.claudeWidgetQuotaOwnerKey()
        } else {
            nil
        }
        let preservedClaudeUsage: PreservedClaudeWidgetUsage? = if provider == .claude,
                                                                   snapshot == nil,
                                                                   !self.widgetUsagePreservationBlockedProviders
                                                                       .contains(provider.instanceID),
                                                                       self
                                                                           .knownLimitsAvailabilityByProvider[provider
                                                                               .instanceID]?
                                                                           .isUnavailable != true
        {
            Self.preservedClaudeWidgetUsage(
                from: previousEntry,
                expectedQuotaOwnerKey: claudeQuotaOwnerKey,
                includesModelScopedWeeklyRows: self.settings.claudeModelScopedWeeklyUsageVisible)
        } else {
            nil
        }
        guard snapshot != nil ||
            (provider == .claude && (tokenSnapshot != nil || preservedClaudeUsage != nil))
        else {
            return nil
        }

        let dailyUsage = tokenSnapshot?.daily.map { entry in
            WidgetSnapshot.DailyUsagePoint(
                dayKey: entry.date,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD)
        } ?? []

        let tokenUsage = Self.widgetTokenUsageSummary(from: tokenSnapshot, provider: provider)
        let usageRows = snapshot.map {
            self.widgetUsageRows(provider: provider, snapshot: $0, now: now)
        } ?? preservedClaudeUsage?.usageRows ?? []

        let creditsRemaining: Double?
        let codeReviewRemaining: Double?
        if provider == .codex, let snapshot {
            let projection = self.codexConsumerProjection(
                surface: .widget,
                snapshotOverride: snapshot,
                now: now)
            let displayOnlyExtrasHidden = projection.dashboardVisibility == .displayOnly
            creditsRemaining = displayOnlyExtrasHidden ? nil : projection.credits?.remaining
            codeReviewRemaining = displayOnlyExtrasHidden ? nil : projection.remainingPercent(for: .codeReview)
        } else {
            creditsRemaining = nil
            codeReviewRemaining = nil
        }
        let providerCost: ProviderCostSnapshot? = if provider == .devin,
                                                     self.settings.showOptionalCreditsAndExtraUsage
        {
            snapshot?.providerCost
        } else {
            nil
        }
        // Provider-specific by design: DeepSeek and OpenRouter expose their widget value as balance text.
        let balanceText: String? = switch provider {
        case .deepseek, .openrouter:
            MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: snapshot)
        default:
            nil
        }

        // Provider-specific by design: Pi's local strategy has no quota measurement; age belongs to its history.
        let historyUpdatedAt = provider == .pi ? tokenSnapshot?.updatedAt : nil
        return WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: historyUpdatedAt ?? snapshot?.updatedAt ?? preservedClaudeUsage?.updatedAt
                ?? tokenSnapshot?.updatedAt ?? now,
            primary: snapshot?.primary ?? preservedClaudeUsage?.primary,
            secondary: snapshot?.secondary ?? preservedClaudeUsage?.secondary,
            tertiary: snapshot?.tertiary ?? preservedClaudeUsage?.tertiary,
            usageRows: usageRows,
            creditsRemaining: creditsRemaining,
            codeReviewRemainingPercent: codeReviewRemaining,
            tokenUsage: tokenUsage,
            dailyUsage: dailyUsage,
            providerCost: providerCost,
            quotaOwnerKey: snapshot != nil ? claudeQuotaOwnerKey : preservedClaudeUsage?.quotaOwnerKey,
            balanceText: balanceText)
    }

    private struct PreservedClaudeWidgetUsage {
        let updatedAt: Date
        let primary: RateWindow?
        let secondary: RateWindow?
        let tertiary: RateWindow?
        let usageRows: [WidgetSnapshot.WidgetUsageRowSnapshot]?
        let quotaOwnerKey: String?
    }

    private func claudeWidgetQuotaOwnerKey() -> String {
        if let account = self.settings.effectiveSelectedTokenAccount(for: .claude) {
            return self.tokenAccountSnapshotCacheKey(provider: .claude, account: account)
        }
        let environment = ProviderRegistry.makeEnvironment(
            base: self.environmentBase,
            provider: .claude,
            settings: self.settings,
            tokenOverride: nil)
        return ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
    }

    private nonisolated static func preservedClaudeWidgetUsage(
        from entry: WidgetSnapshot.ProviderEntry?,
        expectedQuotaOwnerKey: String?,
        includesModelScopedWeeklyRows: Bool) -> PreservedClaudeWidgetUsage?
    {
        guard let entry, entry.provider == .claude else { return nil }
        guard let expectedQuotaOwnerKey,
              let quotaOwnerKey = entry.quotaOwnerKey,
              quotaOwnerKey == expectedQuotaOwnerKey
        else {
            return nil
        }

        let primary = entry.primary?.isSyntheticPlaceholder == true ? nil : entry.primary
        let secondary = entry.secondary?.isSyntheticPlaceholder == true ? nil : entry.secondary
        let tertiary = entry.tertiary?.isSyntheticPlaceholder == true ? nil : entry.tertiary
        let usageRows = entry.usageRows?.filter { row in
            guard row.window?.isSyntheticPlaceholder != true else { return false }
            // Rows persisted while the setting was on must not outlive it: without a live snapshot
            // this preserved list is what widgets render, so re-apply the visibility filter here.
            guard includesModelScopedWeeklyRows ||
                !row.id.hasPrefix(Self.claudeModelScopedWeeklyWindowIDPrefix)
            else {
                return false
            }
            return switch row.id {
            case "primary": primary != nil
            case "secondary": secondary != nil
            case "tertiary": tertiary != nil
            default: row.percentLeft != nil
            }
        }
        guard primary != nil || secondary != nil || tertiary != nil || usageRows?.isEmpty == false else {
            return nil
        }
        return PreservedClaudeWidgetUsage(
            updatedAt: entry.updatedAt,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            usageRows: usageRows,
            quotaOwnerKey: quotaOwnerKey)
    }

    nonisolated static func widgetTokenUsageSummary(
        from snapshot: CostUsageTokenSnapshot?,
        provider: UsageProvider) -> WidgetSnapshot.TokenUsageSummary?
    {
        guard let snapshot else { return nil }
        let fallbackTokens = CheckedSum.integers(snapshot.daily.compactMap(\.totalTokens))
            .flatMap { $0 > 0 ? $0 : nil }
        let sessionLabel = switch provider {
        case .bedrock, .mistral: "Latest billing day"
        default: "Today"
        }
        let defaultMonthLabel = snapshot.historyDays == 1 ? "Today" : "\(snapshot.historyDays)d"
        let monthLabel = snapshot.historyLabel.map { L($0) } ?? defaultMonthLabel
        let estimateSuffix = provider == .codex ? " API est. · not billed" : ""
        return WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionTokens: snapshot.sessionTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysTokens: snapshot.last30DaysTokens ?? fallbackTokens,
            currencyCode: snapshot.currencyCode,
            sessionLabel: sessionLabel + estimateSuffix,
            last30DaysLabel: monthLabel + estimateSuffix,
            updatedAt: snapshot.updatedAt)
    }

    private nonisolated static func widgetPrimaryTitle(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        metadata: ProviderMetadata?) -> String
    {
        let dynamicTitle: String? = switch provider {
        // Legacy request-based Cursor plans track a request quota, not the token-based "Total" pool.
        case .cursor where snapshot.detailRow(label: "Request quota") != nil: "Requests"
        case .grok: GrokProviderDescriptor.displayLabel(window: snapshot.primary)
        case .doubao: DoubaoProviderDescriptor.primaryLabel(window: snapshot.primary)
        case .amp: AmpProviderDescriptor.primaryLabel(snapshot: snapshot)
        case .alibabatokenplan: AlibabaTokenPlanProviderDescriptor.primaryLabel(window: snapshot.primary)
        case .ollama: OllamaProviderDescriptor.primaryLabel(window: snapshot.primary)
        default: nil
        }
        if let dynamicTitle {
            return dynamicTitle
        }
        guard let metadata else { return "Session" }
        return ProviderDescriptorRegistry.descriptor(for: provider).presentation
            .rateWindowLabels(metadata: metadata, snapshot: snapshot).primary
    }

    func widgetUsageRows(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        now: Date) -> [WidgetSnapshot.WidgetUsageRowSnapshot]
    {
        let metadata = ProviderDefaults.metadata[provider]
        if provider == .codex {
            let projection = self.codexConsumerProjection(
                surface: .widget,
                snapshotOverride: snapshot,
                now: now)
            return projection.visibleRateLanes.compactMap { lane in
                guard let window = projection.sourceRateWindow(for: lane) else { return nil }
                let title = CodexConsumerProjection.rateTitle(
                    lane: lane,
                    windowMinutes: window.windowMinutes,
                    sessionLabel: metadata?.sessionLabel ?? "Session",
                    weeklyLabel: metadata?.weeklyLabel ?? "Weekly")
                return WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: lane.rawValue,
                    title: title,
                    percentLeft: window.remainingPercent,
                    window: window)
            }
        }
        if provider == .claude,
           let spendLimit = MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot)
        {
            let period = snapshot.providerCost?.period?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = period.flatMap { $0.isEmpty ? nil : $0 } ?? "Extra usage"
            return [
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "extraUsage",
                    title: title,
                    percentLeft: spendLimit.remainingPercent,
                    window: spendLimit),
            ]
        }
        if provider == .antigravity,
           let rows = Self.antigravityWidgetRows(snapshot: snapshot)
        {
            return rows
        }

        let primaryTitle = Self.widgetPrimaryTitle(provider: provider, snapshot: snapshot, metadata: metadata)
        let secondaryTitle = if provider == .amp {
            AmpProviderDescriptor.secondaryLabel(snapshot: snapshot) ?? metadata?.weeklyLabel ?? "Weekly"
        } else if provider == .alibabatokenplan {
            AlibabaTokenPlanProviderDescriptor.secondaryLabel(window: snapshot.secondary) ??
                metadata?.weeklyLabel ?? "Weekly"
        } else {
            metadata?.weeklyLabel ?? "Weekly"
        }

        var rows: [WidgetSnapshot.WidgetUsageRowSnapshot] = [
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "primary",
                title: primaryTitle,
                percentLeft: snapshot.primary?.remainingPercent),
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "secondary",
                title: secondaryTitle,
                percentLeft: snapshot.secondary?.remainingPercent),
        ]
        if metadata?.supportsOpus == true {
            rows.append(WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "tertiary",
                title: metadata?.opusLabel ?? "Opus",
                percentLeft: snapshot.tertiary?.remainingPercent))
        }
        // Provider-specific by design: Cursor Grok Bot weekly included usage is a named extraRateWindow.
        if provider == .cursor {
            rows.append(contentsOf: (snapshot.extraRateWindows ?? []).compactMap { namedWindow in
                guard namedWindow.id == CursorSandUsageStatus.extraWindowID, namedWindow.usageKnown else {
                    return nil
                }
                return WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: namedWindow.id,
                    title: namedWindow.title,
                    percentLeft: namedWindow.window.remainingPercent,
                    window: namedWindow.window)
            })
        }

        if provider == .claude, self.settings.claudeModelScopedWeeklyUsageVisible {
            // Claude fetchers place model-scoped weekly quotas (for example, Fable) in extraRateWindows.
            // Keep the widget projection generic so newly surfaced Claude model quotas appear without UI changes.
            rows.append(contentsOf: (snapshot.extraRateWindows ?? []).compactMap { namedWindow in
                guard namedWindow.id.hasPrefix(Self.claudeModelScopedWeeklyWindowIDPrefix),
                      namedWindow.usageKnown
                else { return nil }
                return WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: namedWindow.id,
                    title: namedWindow.title,
                    percentLeft: namedWindow.window.remainingPercent,
                    window: namedWindow.window)
            })
        }
        if provider == .kimi {
            // Keep persisted widget order stable and include only Kimi's intentional subscription lanes.
            let kimiWindowIDs = ["kimi-monthly", "kimi-code-7d"]
            rows.append(contentsOf: kimiWindowIDs.compactMap { id in
                guard let window = snapshot.extraRateWindows?.first(where: { $0.id == id }), window.usageKnown
                else { return nil }
                return WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: window.id,
                    title: window.title,
                    percentLeft: window.window.remainingPercent)
            })
        }
        return rows.filter { $0.percentLeft != nil }
    }

    /// Identifier prefix Claude fetchers use for model-scoped weekly carve-outs (for example, Fable).
    private nonisolated static let claudeModelScopedWeeklyWindowIDPrefix = "claude-weekly-scoped-"

    private nonisolated static let antigravityQuotaSummaryWindowIDPrefix = "antigravity-quota-summary-"
    private nonisolated static let antigravityCompactFallbackWindowIDPrefix = "antigravity-compact-fallback-"

    private nonisolated static func antigravityWidgetRows(
        snapshot: UsageSnapshot) -> [WidgetSnapshot.WidgetUsageRowSnapshot]?
    {
        let windows = snapshot.extraRateWindows ?? []
        var visible = windows.filter {
            $0.id.hasPrefix(Self.antigravityQuotaSummaryWindowIDPrefix)
        }
        if !visible.isEmpty {
            // Match the menu card and drop model families the account never touches.
            let idleIDs = AntigravityQuotaFamilyVisibility.idleWindowIDs(in: snapshot)
            visible.removeAll { idleIDs.contains($0.id) }
        }
        if visible.isEmpty, snapshot.primary == nil, snapshot.secondary == nil {
            visible = windows.filter {
                $0.id.hasPrefix(Self.antigravityCompactFallbackWindowIDPrefix) && $0.usageKnown
            }
        }
        guard !visible.isEmpty else { return nil }
        return visible.map { namedWindow in
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: namedWindow.id,
                title: namedWindow.title,
                percentLeft: namedWindow.usageKnown ? namedWindow.window.remainingPercent : nil)
        }
    }
}
