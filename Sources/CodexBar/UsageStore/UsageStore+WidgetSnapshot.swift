import CodexBarCore
import CryptoKit
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
        // Central spot: every snapshot-publishing path (account switches, invalidations) refreshes the CLI cache.
        self.persistCLIUsageCache()
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
        self.invalidatedQueuedWidgetProviders = self.widgetUsagePreservationBlockedProviders
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

            self.lastPublishedWidgetSnapshot = await Self.saveWidgetSnapshot(
                snapshot,
                to: self.widgetSnapshotURL,
                previousPublication: self.lastPublishedWidgetSnapshot,
                isRunningTests: SettingsStore.isRunningTests,
                reloadTimelines: self.widgetTimelineReloader)
        }
    }

    struct WidgetSnapshotPublication: Sendable {
        let contentHash: SHA256.Digest
        let fileHash: SHA256.Digest
    }

    @discardableResult
    static func saveWidgetSnapshot(
        _ snapshot: WidgetSnapshot,
        to url: URL?,
        previousPublication: WidgetSnapshotPublication? = nil,
        isRunningTests: Bool,
        reloadTimelines: @MainActor () -> Void) async -> WidgetSnapshotPublication?
    {
        let (publication, shouldReload) = await Task.detached(priority: .utility) {
            () -> (WidgetSnapshotPublication?, Bool) in
            // Use the writer's canonical encoding so every field except generation time participates.
            var comparable = snapshot
            comparable.generatedAt = Date(timeIntervalSince1970: 0)
            guard let contentHash = try? SHA256.hash(data: WidgetSnapshotStore.encodedData(comparable))
            else { return (nil, true) }
            if let previousPublication, previousPublication.contentHash == contentHash,
               let savedData = WidgetSnapshotStore.loadData(from: url),
               SHA256.hash(data: savedData) == previousPublication.fileHash
            {
                return (previousPublication, false)
            }
            guard let data = try? WidgetSnapshotStore.encodedData(snapshot),
                  WidgetSnapshotStore.save(data: data, to: url)
            else { return (nil, true) }
            return (WidgetSnapshotPublication(contentHash: contentHash, fileHash: SHA256.hash(data: data)), true)
        }.value
        // Failed attempts keep the existing reload behavior but cannot suppress the next write.
        // Opting into file persistence in tests never opts into WidgetKit side effects.
        if shouldReload, !isRunningTests { reloadTimelines() }
        return publication
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
            guard instanceID.firstPartyProvider.map(Self.requiresBrowserSession) != true else { continue }
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
            guard provider.firstPartyProvider.map(Self.requiresBrowserSession) != true else { continue }
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
        if (identities.isEmpty && self.metadata(for: provider).usesAccountFallback) || hasDefaultCodexSnapshot {
            let fallback = self.accountInfo(for: provider)
            insert(fallback.email)
        }
        return identities
    }

    func invalidateGenericWidgetUsage(for provider: UsageProvider) {
        // Provider-specific by design: Claude keeps its existing owner-aware preservation policy.
        guard provider != .claude else { return }
        self.lastWidgetSourceSnapshots[provider.instanceID] = nil
        self.widgetUsagePreservationBlockedProviders.insert(provider.instanceID)
        // A successful fetch cannot make an older queued account valid again.
        self.invalidatedQueuedWidgetProviders.insert(provider.instanceID)
    }

    static func supportsWidgetUsage(_ provider: UsageProvider) -> Bool {
        let metadata = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        return metadata.widgetSelectable || metadata.burnDownWidgetSelectable
    }

    private func makeWidgetSnapshot(previousSnapshot: WidgetSnapshot?) -> WidgetSnapshot {
        let now = Date()
        let widgetProviders = UsageProvider.allCases.filter(Self.supportsWidgetUsage)
        let widgetIDs = Set(widgetProviders.map(\.instanceID))
        let enabledProviders = self.enabledProviders().filter(widgetIDs.contains)
        let entries = widgetProviders.compactMap { provider -> WidgetSnapshot.ProviderEntry? in
            if let entry = self.makeWidgetEntry(
                for: provider,
                now: now,
                previousEntry: previousSnapshot?.entries.first { $0.provider == provider.instanceID })
            { return entry }
            // Provider-specific by design: Claude uses its owner-aware path; others require this process's publication.
            guard provider != .claude, enabledProviders.contains(provider.instanceID),
                  self.errors[provider.instanceID] != nil,
                  !self.invalidatedQueuedWidgetProviders.contains(provider.instanceID),
                  !self.widgetUsagePreservationBlockedProviders.contains(provider.instanceID),
                  let entry = self.lastQueuedWidgetSnapshot?.entries
                      .first(where: { $0.provider == provider.instanceID }),
                      entry.providerCost == nil || self.settings.showOptionalCreditsAndExtraUsage
            else { return nil }
            return self.preservedWidgetEntryForCurrentMetric(entry)
        }
        return WidgetSnapshot(
            entries: entries,
            accounts: self.makeWidgetAccountEntries(now: now),
            accountOverflowCounts: self.widgetAccountOverflowCounts(),
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
        let snapshot = if swapOwnsClaude {
            activeSwapAccount?.snapshot
        } else if provider == .deepseek {
            self.presentationSnapshot(for: .deepseek)
        } else {
            self.snapshots[provider.instanceID]
        }
        let rawTokenSnapshot = self.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot
        let tokenSnapshot: CostUsageTokenSnapshot? = if provider == .deepseek,
                                                        !self.settings.showOptionalCreditsAndExtraUsage
        {
            nil
        } else {
            rawTokenSnapshot
        }
        let claudeQuotaOwnerKey: String? = if swapOwnsClaude {
            activeSwapAccount.flatMap(Self.claudeSwapWidgetOwnerKey(for:))
        } else if provider == .claude {
            self.claudeWidgetQuotaOwnerKey()
        } else {
            nil
        }
        let preservedClaudeUsage: WidgetSnapshot.ProviderEntry? = if provider == .claude,
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

        let deepseekChartProjection: DeepSeekWidgetChartProjection? = if provider == .deepseek,
                                                                         let tokenSnapshot
        {
            Self.deepSeekWidgetChartProjection(from: tokenSnapshot)
        } else {
            nil
        }
        let dailyUsage: [WidgetSnapshot.DailyUsagePoint] = if let deepseekChartProjection {
            deepseekChartProjection.points
        } else {
            tokenSnapshot?.daily.map { entry in
                WidgetSnapshot.DailyUsagePoint(
                    dayKey: entry.date,
                    totalTokens: entry.totalTokens,
                    costUSD: entry.costUSD)
            } ?? []
        }

        let tokenUsage = Self.widgetTokenUsageSummary(
            from: tokenSnapshot,
            provider: provider,
            chartProjection: deepseekChartProjection)
        let usageRows = snapshot.map {
            self.widgetUsageRows(provider: provider, snapshot: $0, now: now)
        } ?? preservedClaudeUsage?.usageRows ?? []
        if ProviderDescriptorRegistry.descriptor(for: provider).presentation.widgetRowsFollowMenuBarMetric,
           let snapshot
        {
            self.lastWidgetSourceSnapshots[provider.instanceID] = snapshot
        }

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

        let widgetDetails = Self.widgetDetails(
            for: provider,
            snapshot: snapshot,
            showOptionalCreditsAndExtraUsage: self.settings.showOptionalCreditsAndExtraUsage)

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
            balanceText: balanceText,
            details: widgetDetails)
    }

    nonisolated static func widgetDetails(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        showOptionalCreditsAndExtraUsage: Bool) -> [ProviderDetailSection]?
    {
        guard let snapshot, !snapshot.details.isEmpty else { return nil }
        guard provider == .deepseek else { return snapshot.details }
        guard showOptionalCreditsAndExtraUsage else { return nil }
        // Widgets render grouped `dailyUsage` bars (<= 45 points), so omit DeepSeek's raw detail charts.
        let stripped = snapshot.details.compactMap { section -> ProviderDetailSection? in
            guard section.chart != nil else { return section }
            guard !section.rows.isEmpty else { return nil }
            return try? ProviderDetailSection(title: section.title, rows: section.rows, chart: nil)
        }
        return stripped.isEmpty ? nil : stripped
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
        includesModelScopedWeeklyRows: Bool) -> WidgetSnapshot.ProviderEntry?
    {
        guard var entry, entry.provider == .claude else { return nil }
        guard let expectedQuotaOwnerKey,
              entry.quotaOwnerKey == expectedQuotaOwnerKey
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
        entry.primary = primary
        entry.secondary = secondary
        entry.tertiary = tertiary
        entry.usageRows = usageRows
        return entry
    }

    struct DeepSeekWidgetChartProjection: Sendable, Equatable {
        let points: [WidgetSnapshot.DailyUsagePoint]
        let chartTitle: String?
        let compactPeriodLabel: String?
        let startDayKey: String?
        let endDayKey: String?
        let bucketDays: Int?
        let prefersCostMode: Bool?
    }

    private struct WidgetDayBucketAggregate: Sendable {
        private(set) var tokens: Int?
        private(set) var tokensInvalid = false
        private(set) var costUSD: Double?
        private(set) var costInvalid = false

        mutating func add(tokens: Int?, costUSD: Double?) {
            self.addTokensOnly(tokens)
            self.addCostOnly(costUSD)
        }

        private mutating func addTokensOnly(_ tokens: Int?) {
            guard let tokens, !self.tokensInvalid else { return }
            guard tokens >= 0 else {
                self.tokensInvalid = true
                self.tokens = nil
                return
            }
            if let existing = self.tokens {
                let addition = existing.addingReportingOverflow(tokens)
                if addition.overflow {
                    self.tokensInvalid = true
                    self.tokens = nil
                } else {
                    self.tokens = addition.partialValue
                }
            } else {
                self.tokens = tokens
            }
        }

        private mutating func addCostOnly(_ costUSD: Double?) {
            guard !self.costInvalid else { return }
            guard let costUSD, costUSD.isFinite, costUSD.sign != .minus else {
                self.costInvalid = true
                self.costUSD = nil
                return
            }
            if let existing = self.costUSD {
                let sum = existing + costUSD
                if sum.isFinite {
                    self.costUSD = sum
                } else {
                    self.costInvalid = true
                    self.costUSD = nil
                }
            } else {
                self.costUSD = costUSD
            }
        }

        mutating func merge(_ other: Self) {
            if other.tokensInvalid {
                self.tokensInvalid = true
                self.tokens = nil
            } else if let otherTokens = other.tokens, !self.tokensInvalid {
                self.addTokensOnly(otherTokens)
            }
            if other.costInvalid {
                self.costInvalid = true
                self.costUSD = nil
            } else if let otherCost = other.costUSD, !self.costInvalid {
                self.addCostOnly(otherCost)
            }
        }
    }

    nonisolated static func deepSeekWidgetChartProjection(
        from snapshot: CostUsageTokenSnapshot,
        maxBuckets: Int = 45) -> DeepSeekWidgetChartProjection
    {
        let calendar = CostUsageLocalDay.fixedOffsetGregorianCalendar(secondsFromGMT: 0)
        var entriesByDay: [String: WidgetDayBucketAggregate] = [:]
        var orderedDayKeys: [String] = []
        for entry in snapshot.daily {
            if entriesByDay[entry.date] == nil {
                orderedDayKeys.append(entry.date)
            }
            var aggregate = entriesByDay[entry.date] ?? WidgetDayBucketAggregate()
            aggregate.add(tokens: entry.totalTokens, costUSD: entry.costUSD)
            entriesByDay[entry.date] = aggregate
        }

        let intervalDates = (snapshot.coveredDayIntervals ?? []).flatMap { interval -> [Date] in
            [
                CostUsageLocalDay.date(fromKey: interval.startDay, calendar: calendar),
                CostUsageLocalDay.date(fromKey: interval.endDay, calendar: calendar),
            ].compactMap(\.self)
        }
        let entryDates = entriesByDay.keys.compactMap { CostUsageLocalDay.date(fromKey: $0, calendar: calendar) }
        let allDates = intervalDates + entryDates
        let hasAnyCost = entriesByDay.values.contains { !$0.costInvalid && $0.costUSD != nil }
        let chartTitle = snapshot.historyLabel
            ?? (snapshot.historyDays == 1 ? "Today" : "Last \(snapshot.historyDays) days")
        let compactLabel = Self.deepSeekCompactWidgetPeriodLabel(from: snapshot)

        guard let startDate = allDates.min(), let endDate = allDates.max() else {
            return DeepSeekWidgetChartProjection(
                points: [],
                chartTitle: chartTitle,
                compactPeriodLabel: compactLabel,
                startDayKey: nil,
                endDayKey: nil,
                bucketDays: nil,
                prefersCostMode: nil)
        }

        let startDayKey = CostUsageLocalDay.key(from: startDate, calendar: calendar)
        let endDayKey = CostUsageLocalDay.key(from: endDate, calendar: calendar)
        let spanDays = max(1, (calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0) + 1)
        let bucketLimit = max(1, maxBuckets)

        if spanDays <= bucketLimit, orderedDayKeys.count <= bucketLimit {
            let points = orderedDayKeys.map { dayKey in
                let aggregate = entriesByDay[dayKey]
                return WidgetSnapshot.DailyUsagePoint(
                    dayKey: dayKey,
                    totalTokens: aggregate?.tokensInvalid == true ? nil : aggregate?.tokens,
                    costUSD: aggregate?.costInvalid == true ? nil : aggregate?.costUSD)
            }
            return DeepSeekWidgetChartProjection(
                points: points,
                chartTitle: chartTitle,
                compactPeriodLabel: compactLabel,
                startDayKey: startDayKey,
                endDayKey: endDayKey,
                bucketDays: nil,
                prefersCostMode: hasAnyCost ? true : nil)
        }

        let bucketDays = Self.calendarAlignedWidgetBucketDays(spanDays: spanDays, maxBuckets: bucketLimit)
        let parsedIntervals: [ClosedRange<Date>] = (snapshot.coveredDayIntervals ?? []).compactMap { interval in
            guard let start = CostUsageLocalDay.date(fromKey: interval.startDay, calendar: calendar),
                  let end = CostUsageLocalDay.date(fromKey: interval.endDay, calendar: calendar),
                  start <= end
            else { return nil }
            return start...end
        }

        // Group backwards from endDate so the newest bar ends cleanly on endDayKey, then reverse to chronological.
        var reversedPoints: [WidgetSnapshot.DailyUsagePoint] = []
        var bucketEnd = endDate
        while bucketEnd >= startDate {
            let candidateStart = calendar.date(byAdding: .day, value: -(bucketDays - 1), to: bucketEnd) ?? startDate
            let bucketStart = max(startDate, candidateStart)

            var bucket = WidgetDayBucketAggregate()
            var sawCoveredDay = parsedIntervals.isEmpty

            var day = bucketStart
            while day <= bucketEnd {
                if !sawCoveredDay, parsedIntervals.contains(where: { $0.contains(day) }) {
                    sawCoveredDay = true
                }
                let key = CostUsageLocalDay.key(from: day, calendar: calendar)
                if let entry = entriesByDay[key] {
                    bucket.merge(entry)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }

            let isNewestBucket = bucketEnd == endDate
            let bucketKey = isNewestBucket
                ? endDayKey
                : CostUsageLocalDay.key(from: bucketStart, calendar: calendar)
            let pointTokens: Int? = if bucket.tokensInvalid {
                nil
            } else if let total = bucket.tokens {
                total
            } else {
                sawCoveredDay ? 0 : nil
            }
            let pointCost: Double? = if bucket.costInvalid {
                nil
            } else if let total = bucket.costUSD {
                total
            } else {
                sawCoveredDay && hasAnyCost ? 0 : nil
            }
            reversedPoints.append(WidgetSnapshot.DailyUsagePoint(
                dayKey: bucketKey,
                totalTokens: pointTokens,
                costUSD: pointCost))

            guard let previousEnd = calendar.date(byAdding: .day, value: -1, to: bucketStart) else { break }
            bucketEnd = previousEnd
        }

        return DeepSeekWidgetChartProjection(
            points: reversedPoints.reversed(),
            chartTitle: chartTitle,
            compactPeriodLabel: compactLabel,
            startDayKey: startDayKey,
            endDayKey: endDayKey,
            bucketDays: bucketDays,
            prefersCostMode: hasAnyCost ? true : nil)
    }

    private nonisolated static func calendarAlignedWidgetBucketDays(spanDays: Int, maxBuckets: Int) -> Int {
        for candidate in [1, 2, 3, 7, 14, 30] where (spanDays + candidate - 1) / candidate <= maxBuckets {
            return candidate
        }
        return max(1, (spanDays + maxBuckets - 1) / maxBuckets)
    }

    private nonisolated static func deepSeekCompactWidgetPeriodLabel(from snapshot: CostUsageTokenSnapshot) -> String? {
        guard let label = snapshot.historyLabel else { return nil }
        if label == "This month" || label == "Month to date" {
            return label
        }
        if let intervals = snapshot.coveredDayIntervals, snapshot.historyScanIsPartial {
            let calendar = CostUsageLocalDay.fixedOffsetGregorianCalendar(secondsFromGMT: 0)
            let coveredDays = intervals.reduce(0) { sum, interval in
                guard let start = CostUsageLocalDay.date(fromKey: interval.startDay, calendar: calendar),
                      let end = CostUsageLocalDay.date(fromKey: interval.endDay, calendar: calendar),
                      start <= end
                else { return sum }
                return sum + (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
            }
            if coveredDays > 0, coveredDays < snapshot.historyDays {
                return "\(coveredDays)/\(snapshot.historyDays)d"
            }
        }
        if label == "Last \(snapshot.historyDays) days" {
            return "\(snapshot.historyDays)d"
        }
        return label
    }

    nonisolated static func widgetTokenUsageSummary(
        from snapshot: CostUsageTokenSnapshot?,
        provider: UsageProvider,
        chartProjection: DeepSeekWidgetChartProjection? = nil) -> WidgetSnapshot.TokenUsageSummary?
    {
        guard let snapshot else { return nil }
        let dailyTokens = snapshot.daily.compactMap(\.totalTokens)
        let fallbackTokens: Int? = if dailyTokens.contains(where: { $0 < 0 }) {
            nil
        } else {
            CheckedSum.integers(dailyTokens).flatMap { $0 > 0 ? $0 : nil }
        }
        let validCost: (Double?) -> Double? = { value in
            guard let value, value.isFinite, value.sign != .minus else { return nil }
            return value
        }
        let sessionTokens = snapshot.sessionTokens.flatMap { $0 >= 0 ? $0 : nil }
        let last30DaysTokens: Int? = if let reported = snapshot.last30DaysTokens {
            reported >= 0 ? reported : nil
        } else {
            fallbackTokens
        }
        let sessionLabel = switch provider {
        case .bedrock, .mistral: "Latest billing day"
        default: "Today"
        }
        let defaultMonthLabel = snapshot.historyDays == 1 ? "Today" : "\(snapshot.historyDays)d"
        let monthLabel = chartProjection?.compactPeriodLabel ?? snapshot.historyLabel ?? defaultMonthLabel
        let estimateSuffix = provider == .codex ? " API est. · not billed" : ""
        return WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: validCost(snapshot.sessionCostUSD),
            sessionTokens: sessionTokens,
            last30DaysCostUSD: validCost(snapshot.last30DaysCostUSD),
            last30DaysTokens: last30DaysTokens,
            currencyCode: snapshot.currencyCode,
            sessionLabel: sessionLabel + estimateSuffix,
            last30DaysLabel: monthLabel + estimateSuffix,
            updatedAt: snapshot.updatedAt,
            chartTitle: chartProjection?.chartTitle,
            chartStartDayKey: chartProjection?.startDayKey,
            chartEndDayKey: chartProjection?.endDayKey,
            chartBucketDays: chartProjection?.bucketDays,
            chartPrefersCostMode: chartProjection?.prefersCostMode)
    }

    private nonisolated static func widgetPrimaryTitle(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        metadata: ProviderMetadata?) -> String
    {
        let dynamicTitle: String? = switch provider {
        // Legacy request-based Cursor plans track a request quota, not the token-based "Total" pool.
        case .cursor where snapshot.detailRow(label: "Request quota") != nil: "Requests"
        case .cursor: CursorProviderDescriptor.primaryLabel(snapshot: snapshot)
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
            metadata.map {
                ProviderDescriptorRegistry.descriptor(for: provider).presentation
                    .rateWindowLabels(metadata: $0, snapshot: snapshot, now: now).secondary
            } ?? "Weekly"
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
        var extraWindows: [NamedRateWindow] = []
        var includesWindow = true
        // Provider-specific by design: keep each provider's existing selection and wire shape.
        if provider == .cursor {
            extraWindows = (snapshot.extraRateWindows ?? []).filter { $0.id == CursorSandUsageStatus.extraWindowID }
        }
        if provider == .claude, self.settings.claudeModelScopedWeeklyUsageVisible {
            extraWindows = (snapshot.extraRateWindows ?? []).filter {
                $0.id.hasPrefix(Self.claudeModelScopedWeeklyWindowIDPrefix)
            }
        }
        if provider == .kimi {
            // Kimi persists its subscription lanes in this order, without the optional raw window.
            includesWindow = false
            extraWindows = ["kimi-monthly", "kimi-code-7d"].compactMap { id in
                snapshot.extraRateWindows?.first { $0.id == id }
            }
        }
        rows.append(contentsOf: extraWindows.compactMap { namedWindow in
            guard namedWindow.usageKnown else { return nil }
            return WidgetSnapshot.WidgetUsageRowSnapshot(
                id: namedWindow.id,
                title: namedWindow.title,
                percentLeft: namedWindow.window.remainingPercent,
                window: includesWindow ? namedWindow.window : nil)
        })
        return ProviderDescriptorRegistry.descriptor(for: provider).presentation.widgetRows(
            rows,
            snapshot: snapshot,
            metric: self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot).providerMetric)
            .filter { $0.percentLeft != nil }
    }

    /// Identifier prefix Claude fetchers use for model-scoped weekly carve-outs (for example, Fable).
    private nonisolated static let claudeModelScopedWeeklyWindowIDPrefix = "claude-weekly-scoped-"

    private nonisolated static let antigravityQuotaSummaryWindowIDPrefix = "antigravity-quota-summary-"
    private nonisolated static let antigravityCompactFallbackWindowIDPrefix = "antigravity-compact-fallback-"

    private nonisolated static func antigravityWidgetRows(
        snapshot: UsageSnapshot) -> [WidgetSnapshot.WidgetUsageRowSnapshot]?
    {
        let windows = snapshot.extraRateWindows ?? []
        // Match the menu card and drop model families the account never touches.
        let idleIDs = AntigravityQuotaFamilyVisibility.idleWindowIDs(in: snapshot)
        var visible = windows.filter {
            $0.id.hasPrefix(Self.antigravityQuotaSummaryWindowIDPrefix) && !idleIDs.contains($0.id)
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
                percentLeft: namedWindow.usageKnown ? namedWindow.window.remainingPercent : nil,
                // Unknown buckets have placeholder capacity; only measured windows may supply it.
                window: namedWindow.usageKnown ? namedWindow.window : nil)
        }
    }

    /// Reproject the last published source without changing its measurement time.
    private func preservedWidgetEntryForCurrentMetric(
        _ entry: WidgetSnapshot.ProviderEntry) -> WidgetSnapshot.ProviderEntry
    {
        guard let provider = entry.provider.firstPartyProvider,
              ProviderDescriptorRegistry.descriptor(for: provider).presentation.widgetRowsFollowMenuBarMetric,
              let snapshot = self.lastWidgetSourceSnapshots[entry.provider]
        else { return entry }
        var entry = entry
        entry.usageRows = self.widgetUsageRows(provider: provider, snapshot: snapshot, now: entry.updatedAt)
        return entry
    }
}
