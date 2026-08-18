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

            let widgetSnapshotURL = self.widgetSnapshotURL
            await Task.detached(priority: .utility) {
                if let widgetSnapshotURL {
                    WidgetSnapshotStore.save(snapshot, to: widgetSnapshotURL)
                } else {
                    WidgetSnapshotStore.save(snapshot)
                }
            }.value
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
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
                displayLabel: accountSnapshot.displayLabel,
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
        if let usage = self.snapshots[provider.instanceID] {
            insert(usage.identity?.accountID ?? usage.identity?.accountEmail)
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

    private func makeWidgetSnapshot(previousSnapshot: WidgetSnapshot?) -> WidgetSnapshot {
        let now = Date()
        let enabledProviders = self.enabledProviders()
        let entries = UsageProvider.allCases.compactMap { provider in
            self.makeWidgetEntry(
                for: provider,
                now: now,
                previousEntry: previousSnapshot?.entries.first { $0.provider == provider.instanceID })
        }
        return WidgetSnapshot(
            entries: entries,
            enabledProviders: enabledProviders,
            usageBarsShowUsed: self.settings.usageBarsShowUsed,
            generatedAt: now)
    }

    private func makeWidgetEntry(
        for provider: UsageProvider,
        now: Date,
        previousEntry: WidgetSnapshot.ProviderEntry?) -> WidgetSnapshot.ProviderEntry?
    {
        let snapshot = self.snapshots[provider.instanceID]
        let storedTokenSnapshot = self.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot
        let claudeQuotaOwnerKey: String? = if provider == .claude {
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
            (provider == .claude && (storedTokenSnapshot != nil || preservedClaudeUsage != nil))
        else {
            return nil
        }

        let tokenSnapshot = storedTokenSnapshot
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
        let quotaOwnerKey: String? = if provider == .claude {
            snapshot != nil ? claudeQuotaOwnerKey : preservedClaudeUsage?.quotaOwnerKey
        } else {
            nil
        }

        return WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: snapshot?.updatedAt ?? preservedClaudeUsage?.updatedAt ?? tokenSnapshot?.updatedAt ?? now,
            primary: snapshot?.primary ?? preservedClaudeUsage?.primary,
            secondary: snapshot?.secondary ?? preservedClaudeUsage?.secondary,
            tertiary: snapshot?.tertiary ?? preservedClaudeUsage?.tertiary,
            usageRows: usageRows,
            creditsRemaining: creditsRemaining,
            codeReviewRemainingPercent: codeReviewRemaining,
            tokenUsage: tokenUsage,
            dailyUsage: dailyUsage,
            providerCost: providerCost,
            quotaOwnerKey: quotaOwnerKey)
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
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        let sessionLabel = if provider == .bedrock || provider == .mistral {
            "Latest billing day"
        } else if provider == .codex {
            "Today API est. · not billed"
        } else {
            "Today"
        }
        let defaultMonthLabel = snapshot.historyDays == 1 ? "Today" : "\(snapshot.historyDays)d"
        let monthLabel = if provider == .codex {
            "\(snapshot.historyLabel ?? defaultMonthLabel) API est. · not billed"
        } else {
            snapshot.historyLabel ?? defaultMonthLabel
        }
        return WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionTokens: snapshot.sessionTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysTokens: monthTokensValue,
            currencyCode: snapshot.currencyCode,
            sessionLabel: sessionLabel,
            last30DaysLabel: monthLabel,
            updatedAt: snapshot.updatedAt)
    }

    private func widgetUsageRows(
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
           let rows = Self.antigravityQuotaSummaryWidgetRows(snapshot: snapshot),
           !rows.isEmpty
        {
            return rows
        }
        if provider == .antigravity,
           snapshot.primary == nil,
           snapshot.secondary == nil,
           let rows = Self.antigravityLegacyExtraWidgetRows(snapshot: snapshot),
           !rows.isEmpty
        {
            return rows
        }

        let primaryTitle: String = {
            // Legacy request-based Cursor plans track a request quota, not the token-based "Total" pool.
            if provider == .cursor, snapshot.detailRow(label: "Request quota") != nil {
                return "Requests"
            }
            if provider == .grok,
               let dyn = GrokProviderDescriptor.displayLabel(window: snapshot.primary)
            {
                return dyn
            }
            if provider == .doubao,
               let dyn = DoubaoProviderDescriptor.primaryLabel(window: snapshot.primary)
            {
                return dyn
            }
            if provider == .amp,
               let dyn = AmpProviderDescriptor.primaryLabel(snapshot: snapshot)
            {
                return dyn
            }
            if provider == .crof {
                return CrofProviderDescriptor.primaryLabel(snapshot: snapshot)
            }
            if provider == .alibabatokenplan,
               let dyn = AlibabaTokenPlanProviderDescriptor.primaryLabel(window: snapshot.primary)
            {
                return dyn
            }
            return metadata?.sessionLabel ?? "Session"
        }()
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

    private nonisolated static func antigravityQuotaSummaryWidgetRows(
        snapshot: UsageSnapshot) -> [WidgetSnapshot.WidgetUsageRowSnapshot]?
    {
        guard let windows = snapshot.extraRateWindows?.filter({
            $0.id.hasPrefix(Self.antigravityQuotaSummaryWindowIDPrefix)
        }), !windows.isEmpty else {
            return nil
        }
        // Match the menu card and drop model families the account never touches.
        let idleIDs = AntigravityQuotaFamilyVisibility.idleWindowIDs(in: snapshot)
        return windows.filter { !idleIDs.contains($0.id) }.map { namedWindow in
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: namedWindow.id,
                title: namedWindow.title,
                percentLeft: namedWindow.usageKnown ? namedWindow.window.remainingPercent : nil)
        }
    }

    private nonisolated static func antigravityLegacyExtraWidgetRows(
        snapshot: UsageSnapshot) -> [WidgetSnapshot.WidgetUsageRowSnapshot]?
    {
        let windows = snapshot.extraRateWindows?
            .filter { $0.id.hasPrefix(Self.antigravityCompactFallbackWindowIDPrefix) && $0.usageKnown }
        guard let windows, !windows.isEmpty else { return nil }
        return windows.map { namedWindow in
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: namedWindow.id,
                title: namedWindow.title,
                percentLeft: namedWindow.window.remainingPercent)
        }
    }
}
