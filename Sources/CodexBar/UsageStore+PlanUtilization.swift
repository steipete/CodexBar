import CodexBarCore
import Foundation

extension UsageStore {
    private nonisolated static let weeklyLimitResetThreshold = 1.0
    private nonisolated static let weeklyLimitResetDetectorDefaultsKey = "weeklyLimitResetDetectorStates"
    private nonisolated static let weeklyWindowMinutes = 7 * 24 * 60

    struct WeeklyLimitResetDetectorState: Codable, Equatable {
        let wasAboveThreshold: Bool
        let lastObservedAt: Date
    }

    func supportsPlanUtilizationHistory(for provider: UsageProvider) -> Bool {
        switch provider {
        case .codex, .claude:
            true
        default:
            false
        }
    }

    private nonisolated static let planUtilizationMinSampleIntervalSeconds: TimeInterval = 60 * 60
    private nonisolated static let planUtilizationResetEquivalenceToleranceSeconds: TimeInterval = 2 * 60
    private nonisolated static let planUtilizationMaxSamples: Int = 24 * 730

    private struct PlanUtilizationSeriesKey: Hashable {
        let name: PlanUtilizationSeriesName
        let windowMinutes: Int
    }

    private struct PlanUtilizationSeriesSample {
        let name: PlanUtilizationSeriesName
        let windowMinutes: Int
        let entry: PlanUtilizationHistoryEntry
    }

    func planUtilizationHistory(for provider: UsageProvider) -> [PlanUtilizationSeriesHistory] {
        var providerBuckets = self.planUtilizationHistory[provider] ?? PlanUtilizationHistoryBuckets()
        let originalProviderBuckets = providerBuckets
        let accountKey = self.resolvePlanUtilizationAccountKey(
            provider: provider,
            snapshot: self.snapshots[provider],
            preferredAccount: nil,
            providerBuckets: &providerBuckets)
        self.planUtilizationHistory[provider] = providerBuckets
        if providerBuckets != originalProviderBuckets {
            let snapshotToPersist = self.planUtilizationHistory
            Task {
                await self.planUtilizationPersistenceCoordinator.enqueue(snapshotToPersist)
            }
        }
        return providerBuckets.histories(for: accountKey)
    }

    func shouldShowRefreshingMenuCard(for provider: UsageProvider) -> Bool {
        let isRefreshing = self.isRefreshing || self.refreshingProviders.contains(provider)
        return isRefreshing
            && self.snapshots[provider] == nil
            && self.error(for: provider) == nil
    }

    func shouldHidePlanUtilizationMenuItem(for provider: UsageProvider) -> Bool {
        guard self.supportsPlanUtilizationHistory(for: provider) else { return true }
        return self.shouldShowRefreshingMenuCard(for: provider)
    }

    func recordPlanUtilizationHistorySample(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        account: ProviderTokenAccount? = nil,
        shouldUpdatePreferredAccountKey: Bool = true,
        shouldAdoptUnscopedHistory: Bool = true,
        now: Date = Date())
        async
    {
        let samples = self.planUtilizationSeriesSamples(provider: provider, snapshot: snapshot, capturedAt: now)
        guard !samples.isEmpty else { return }

        let detectorAccountKey = self.planUtilizationAccountKey(
            for: provider,
            snapshot: snapshot,
            preferredAccount: account)
        await MainActor.run {
            self.postWeeklyLimitResetCelebrationIfNeeded(
                provider: provider,
                account: account,
                snapshot: snapshot,
                accountKey: detectorAccountKey,
                samples: samples)
        }

        guard self.supportsPlanUtilizationHistory(for: provider) else { return }
        guard !self.shouldDeferClaudePlanUtilizationHistory(provider: provider) else { return }

        var snapshotToPersist: [UsageProvider: PlanUtilizationHistoryBuckets]?
        await MainActor.run {
            var providerBuckets = self.planUtilizationHistory[provider] ?? PlanUtilizationHistoryBuckets()
            let preferredAccount = account ?? self.settings.selectedTokenAccount(for: provider)
            let accountKey = self.resolvePlanUtilizationAccountKey(
                provider: provider,
                snapshot: snapshot,
                preferredAccount: preferredAccount,
                shouldUpdatePreferredAccountKey: shouldUpdatePreferredAccountKey,
                shouldAdoptUnscopedHistory: shouldAdoptUnscopedHistory,
                providerBuckets: &providerBuckets)
            let histories = providerBuckets.histories(for: accountKey)

            guard let updatedHistories = Self.updatedPlanUtilizationHistories(
                existingHistories: histories,
                samples: samples)
            else {
                return
            }

            providerBuckets.setHistories(updatedHistories, for: accountKey)
            self.planUtilizationHistory[provider] = providerBuckets
            snapshotToPersist = self.planUtilizationHistory
        }

        guard let snapshotToPersist else { return }
        await self.planUtilizationPersistenceCoordinator.enqueue(snapshotToPersist)
    }

    private nonisolated static func updatedPlanUtilizationHistories(
        existingHistories: [PlanUtilizationSeriesHistory],
        samples: [PlanUtilizationSeriesSample]) -> [PlanUtilizationSeriesHistory]?
    {
        guard !samples.isEmpty else { return nil }

        var historiesByKey = Dictionary(uniqueKeysWithValues: existingHistories.map {
            (PlanUtilizationSeriesKey(name: $0.name, windowMinutes: $0.windowMinutes), $0)
        })
        var didChange = false

        for sample in samples {
            let key = PlanUtilizationSeriesKey(name: sample.name, windowMinutes: sample.windowMinutes)
            if let existingHistory = historiesByKey[key] {
                guard let updatedEntries = self.updatedPlanUtilizationEntries(
                    existingEntries: existingHistory.entries,
                    entry: sample.entry)
                else {
                    continue
                }
                historiesByKey[key] = PlanUtilizationSeriesHistory(
                    name: sample.name,
                    windowMinutes: sample.windowMinutes,
                    entries: updatedEntries)
            } else {
                historiesByKey[key] = PlanUtilizationSeriesHistory(
                    name: sample.name,
                    windowMinutes: sample.windowMinutes,
                    entries: [sample.entry])
            }
            didChange = true
        }

        guard didChange else { return nil }
        return historiesByKey.values.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }

    private nonisolated static func updatedPlanUtilizationEntries(
        existingEntries: [PlanUtilizationHistoryEntry],
        entry: PlanUtilizationHistoryEntry) -> [PlanUtilizationHistoryEntry]?
    {
        var entries = existingEntries
        let insertionIndex = entries.firstIndex(where: { $0.capturedAt > entry.capturedAt }) ?? entries.endIndex
        let sampleHourBucket = self.planUtilizationHourBucket(for: entry.capturedAt)
        let sameHourRange = self.planUtilizationHourRange(
            entries: entries,
            insertionIndex: insertionIndex,
            hourBucket: sampleHourBucket)
        let existingHourEntries = Array(entries[sameHourRange])
        let canonicalHourEntries = self.canonicalPlanUtilizationHourEntries(
            existingHourEntries: existingHourEntries,
            incomingEntry: entry)

        guard canonicalHourEntries != existingHourEntries else { return nil }
        entries.replaceSubrange(sameHourRange, with: canonicalHourEntries)

        if entries.count > self.planUtilizationMaxSamples {
            entries.removeFirst(entries.count - self.planUtilizationMaxSamples)
        }
        return entries
    }

    #if DEBUG
    nonisolated static func _updatedPlanUtilizationEntriesForTesting(
        existingEntries: [PlanUtilizationHistoryEntry],
        entry: PlanUtilizationHistoryEntry) -> [PlanUtilizationHistoryEntry]?
    {
        self.updatedPlanUtilizationEntries(existingEntries: existingEntries, entry: entry)
    }

    nonisolated static func _updatedPlanUtilizationHistoriesForTesting(
        existingHistories: [PlanUtilizationSeriesHistory],
        samples: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory]?
    {
        let normalized = samples.flatMap { history in
            history.entries.map { entry in
                PlanUtilizationSeriesSample(name: history.name, windowMinutes: history.windowMinutes, entry: entry)
            }
        }
        return self.updatedPlanUtilizationHistories(existingHistories: existingHistories, samples: normalized)
    }

    nonisolated static var _planUtilizationMaxSamplesForTesting: Int {
        self.planUtilizationMaxSamples
    }
    #endif

    private nonisolated static func clampedPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return max(0, min(100, value))
    }

    private func postWeeklyLimitResetCelebrationIfNeeded(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot,
        accountKey: String?,
        samples: [PlanUtilizationSeriesSample])
    {
        guard let weeklySample = samples.last(where: { $0.name == .weekly }) else { return }

        let accountIdentifier = self.weeklyLimitResetAccountIdentifier(
            provider: provider,
            account: account,
            snapshot: snapshot,
            accountKey: accountKey)
        let detectorKey = Self.weeklyLimitResetDetectorStateKey(
            provider: provider,
            accountIdentifier: accountIdentifier)
        let currentUsed = weeklySample.entry.usedPercent
        let currentObservedAt = weeklySample.entry.capturedAt
        let wasAboveThreshold = currentUsed > Self.weeklyLimitResetThreshold
        if let existingState = self.weeklyLimitResetDetectorStates[detectorKey],
           currentObservedAt <= existingState.lastObservedAt
        {
            return
        }

        let shouldPost = self.weeklyLimitResetDetectorStates[detectorKey]?.wasAboveThreshold == true
            && !wasAboveThreshold
        self.weeklyLimitResetDetectorStates[detectorKey] = WeeklyLimitResetDetectorState(
            wasAboveThreshold: wasAboveThreshold,
            lastObservedAt: currentObservedAt)
        self.persistWeeklyLimitResetDetectorStates()

        guard shouldPost else { return }
        let accountLabel = self.weeklyLimitResetAccountLabel(
            provider: provider,
            account: account,
            snapshot: snapshot)
        let event = WeeklyLimitResetEvent(
            provider: provider,
            accountIdentifier: accountIdentifier,
            accountLabel: accountLabel,
            usedPercent: currentUsed)

        CodexBarLog.logger(LogCategories.confetti).info(
            "Weekly limit reset",
            metadata: [
                "provider": provider.rawValue,
                "accountIdentifier": accountIdentifier,
                "accountLabel": accountLabel ?? "",
                "usedPercent": String(format: "%.2f", currentUsed),
                "observedAt": String(format: "%.0f", currentObservedAt.timeIntervalSince1970),
            ])
        NotificationCenter.default.post(name: .codexbarWeeklyLimitReset, object: event)
    }

    private func planUtilizationSeriesSamples(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        capturedAt: Date) -> [PlanUtilizationSeriesSample]
    {
        var samplesByKey: [PlanUtilizationSeriesKey: PlanUtilizationSeriesSample] = [:]

        func appendWindow(_ window: RateWindow?, name: PlanUtilizationSeriesName?) {
            guard let name,
                  let window,
                  let windowMinutes = window.windowMinutes,
                  windowMinutes > 0,
                  let usedPercent = Self.clampedPercent(window.usedPercent)
            else {
                return
            }

            let key = PlanUtilizationSeriesKey(name: name, windowMinutes: windowMinutes)
            samplesByKey[key] = PlanUtilizationSeriesSample(
                name: name,
                windowMinutes: windowMinutes,
                entry: PlanUtilizationHistoryEntry(
                    capturedAt: capturedAt,
                    usedPercent: usedPercent,
                    resetsAt: window.resetsAt))
        }

        switch provider {
        case .codex:
            let projection = self.codexConsumerProjection(
                surface: .liveCard,
                snapshotOverride: snapshot,
                now: capturedAt)
            for lane in projection.planUtilizationLanes {
                appendWindow(lane.window, name: lane.role)
            }
        case .claude:
            appendWindow(snapshot.primary, name: .session)
            appendWindow(snapshot.secondary, name: .weekly)
            appendWindow(snapshot.tertiary, name: .opus)
        default:
            for window in [snapshot.primary, snapshot.secondary, snapshot.tertiary] {
                guard let window, window.windowMinutes == Self.weeklyWindowMinutes else { continue }
                appendWindow(window, name: .weekly)
            }
        }

        return samplesByKey.values.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }

    private nonisolated static func planUtilizationHourBucket(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / self.planUtilizationMinSampleIntervalSeconds))
    }

    private nonisolated static func planUtilizationHourRange(
        entries: [PlanUtilizationHistoryEntry],
        insertionIndex: Int,
        hourBucket: Int64) -> Range<Int>
    {
        var lowerBound = insertionIndex
        while lowerBound > entries.startIndex {
            let previousIndex = lowerBound - 1
            let previousHourBucket = self.planUtilizationHourBucket(for: entries[previousIndex].capturedAt)
            guard previousHourBucket == hourBucket else { break }
            lowerBound = previousIndex
        }

        var upperBound = insertionIndex
        while upperBound < entries.endIndex {
            let currentHourBucket = self.planUtilizationHourBucket(for: entries[upperBound].capturedAt)
            guard currentHourBucket == hourBucket else { break }
            upperBound += 1
        }

        return lowerBound..<upperBound
    }

    private nonisolated static func canonicalPlanUtilizationHourEntries(
        existingHourEntries: [PlanUtilizationHistoryEntry],
        incomingEntry: PlanUtilizationHistoryEntry) -> [PlanUtilizationHistoryEntry]
    {
        let hourlyObservations = (existingHourEntries + [incomingEntry]).sorted { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            if lhs.usedPercent != rhs.usedPercent {
                return lhs.usedPercent < rhs.usedPercent
            }
            let lhsReset = lhs.resetsAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970
            let rhsReset = rhs.resetsAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970
            return lhsReset < rhsReset
        }
        guard var activeSegmentPeak = hourlyObservations.first else { return [] }

        var peakBeforeLatestReset: PlanUtilizationHistoryEntry?

        for observation in hourlyObservations.dropFirst() {
            if self.startsNewPlanUtilizationResetSegment(
                activeSegmentPeak: activeSegmentPeak,
                observation: observation)
            {
                if peakBeforeLatestReset == nil {
                    peakBeforeLatestReset = activeSegmentPeak
                }
                activeSegmentPeak = observation
                continue
            }

            activeSegmentPeak = self.segmentPeakEntry(
                existingPeak: activeSegmentPeak,
                observation: observation)
        }

        if let peakBeforeLatestReset {
            return [peakBeforeLatestReset, activeSegmentPeak]
        }
        return [activeSegmentPeak]
    }

    private nonisolated static func startsNewPlanUtilizationResetSegment(
        activeSegmentPeak: PlanUtilizationHistoryEntry,
        observation: PlanUtilizationHistoryEntry) -> Bool
    {
        self.haveMeaningfullyDifferentResetBoundaries(
            activeSegmentPeak.resetsAt,
            observation.resetsAt)
    }

    private nonisolated static func segmentPeakEntry(
        existingPeak: PlanUtilizationHistoryEntry,
        observation: PlanUtilizationHistoryEntry) -> PlanUtilizationHistoryEntry
    {
        if existingPeak.resetsAt == nil, observation.resetsAt != nil {
            return observation
        }

        let hasHigherUsage = observation.usedPercent > existingPeak.usedPercent
        let tiesUsageAndIsMoreRecent = observation.usedPercent == existingPeak.usedPercent
            && observation.capturedAt >= existingPeak.capturedAt
        let observationShouldReplacePeak = hasHigherUsage || tiesUsageAndIsMoreRecent
        let peakSource = observationShouldReplacePeak ? observation : existingPeak
        let preferObservationMetadata = observation.capturedAt >= existingPeak.capturedAt

        return PlanUtilizationHistoryEntry(
            capturedAt: peakSource.capturedAt,
            usedPercent: peakSource.usedPercent,
            resetsAt: self.preferredResetBoundary(
                existing: existingPeak.resetsAt,
                incoming: observation.resetsAt,
                preferIncoming: preferObservationMetadata))
    }

    private nonisolated static func haveMeaningfullyDifferentResetBoundaries(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            abs(lhs.timeIntervalSince(rhs)) >= self.planUtilizationResetEquivalenceToleranceSeconds
        case (.none, .none):
            false
        default:
            false
        }
    }

    private nonisolated static func preferredResetBoundary(
        existing: Date?,
        incoming: Date?,
        preferIncoming: Bool) -> Date?
    {
        if preferIncoming {
            return incoming ?? existing
        }
        return existing ?? incoming
    }

    private func planUtilizationAccountKey(
        for provider: UsageProvider,
        snapshot: UsageSnapshot? = nil,
        preferredAccount: ProviderTokenAccount? = nil) -> String?
    {
        let account = preferredAccount ?? self.settings.selectedTokenAccount(for: provider)
        let accountKey = Self.planUtilizationAccountKey(provider: provider, account: account)
        if let accountKey {
            return accountKey
        }
        let resolvedSnapshot = snapshot ?? self.snapshots[provider]
        return resolvedSnapshot.flatMap { Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: $0) }
    }

    private nonisolated static func planUtilizationAccountKey(
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> String?
    {
        guard let account else { return nil }
        return self.sha256Hex("\(provider.rawValue):token-account:\(account.id.uuidString.lowercased())")
    }

    private nonisolated static func planUtilizationIdentityAccountKey(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> String?
    {
        guard let identity = snapshot.identity(for: provider) else { return nil }

        let normalizedEmail = identity.accountEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedEmail, !normalizedEmail.isEmpty {
            if provider == .codex {
                return CodexHistoryOwnership.canonicalEmailHashKey(for: normalizedEmail)
            }
            return self.sha256Hex("\(provider.rawValue):email:\(normalizedEmail)")
        }

        if provider == .claude {
            return nil
        }

        let normalizedOrganization = identity.accountOrganization?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedOrganization, !normalizedOrganization.isEmpty {
            return self.sha256Hex("\(provider.rawValue):organization:\(normalizedOrganization)")
        }

        return nil
    }

    private func shouldDeferClaudePlanUtilizationHistory(provider: UsageProvider) -> Bool {
        provider == .claude && self.shouldHidePlanUtilizationMenuItem(for: .claude)
    }

    private func weeklyLimitResetAccountIdentifier(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot,
        accountKey: String?) -> String
    {
        let identity = snapshot.identity(for: provider)
        return account?.id.uuidString.lowercased()
            ?? accountKey
            ?? identity?.accountEmail
            ?? identity?.accountOrganization
            ?? provider.rawValue
    }

    private func weeklyLimitResetAccountLabel(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot) -> String?
    {
        let identity = snapshot.identity(for: provider)
        return account?.label
            ?? identity?.accountEmail
            ?? identity?.accountOrganization
    }

    private nonisolated static func weeklyLimitResetDetectorStateKey(
        provider: UsageProvider,
        accountIdentifier: String) -> String
    {
        "\(provider.rawValue):\(accountIdentifier)"
    }

    nonisolated static func loadWeeklyLimitResetDetectorStates(from userDefaults: UserDefaults)
        -> [String: WeeklyLimitResetDetectorState]
    {
        guard let data = userDefaults.data(forKey: self.weeklyLimitResetDetectorDefaultsKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: WeeklyLimitResetDetectorState].self, from: data)
        } catch {
            CodexBarLog.logger(LogCategories.confetti).error(
                "Failed to decode weekly limit reset detector state",
                metadata: ["error": String(describing: error)])
            return [:]
        }
    }

    private func persistWeeklyLimitResetDetectorStates() {
        do {
            let data = try JSONEncoder().encode(self.weeklyLimitResetDetectorStates)
            self.settings.userDefaults.set(data, forKey: Self.weeklyLimitResetDetectorDefaultsKey)
        } catch {
            CodexBarLog.logger(LogCategories.confetti).error(
                "Failed to encode weekly limit reset detector state",
                metadata: ["error": String(describing: error)])
        }
    }

    private func resolvePlanUtilizationAccountKey(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        preferredAccount: ProviderTokenAccount?,
        shouldUpdatePreferredAccountKey: Bool = true,
        shouldAdoptUnscopedHistory: Bool = true,
        providerBuckets: inout PlanUtilizationHistoryBuckets) -> String?
    {
        if provider == .codex {
            return self.resolveCodexPlanUtilizationAccountKey(
                snapshot: snapshot,
                shouldUpdatePreferredAccountKey: shouldUpdatePreferredAccountKey,
                shouldAdoptUnscopedHistory: shouldAdoptUnscopedHistory,
                providerBuckets: &providerBuckets)
        }

        let resolvedAccount = preferredAccount ?? self.settings.selectedTokenAccount(for: provider)
        if let tokenAccountKey = Self.planUtilizationAccountKey(provider: provider, account: resolvedAccount) {
            if shouldUpdatePreferredAccountKey {
                providerBuckets.preferredAccountKey = tokenAccountKey
            }
            if shouldAdoptUnscopedHistory {
                self.adoptPlanUtilizationUnscopedHistoryIfNeeded(
                    into: tokenAccountKey,
                    provider: provider,
                    providerBuckets: &providerBuckets)
            }
            return tokenAccountKey
        }

        if let snapshot,
           let identityAccountKey = Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: snapshot)
        {
            if shouldUpdatePreferredAccountKey {
                providerBuckets.preferredAccountKey = identityAccountKey
            }
            if shouldAdoptUnscopedHistory {
                self.adoptPlanUtilizationUnscopedHistoryIfNeeded(
                    into: identityAccountKey,
                    provider: provider,
                    providerBuckets: &providerBuckets)
            }
            return identityAccountKey
        }

        if let stickyAccountKey = self.stickyPlanUtilizationAccountKey(providerBuckets: providerBuckets) {
            return stickyAccountKey
        }

        return nil
    }

    private func resolveCodexPlanUtilizationAccountKey(
        snapshot: UsageSnapshot?,
        shouldUpdatePreferredAccountKey: Bool,
        shouldAdoptUnscopedHistory: Bool,
        providerBuckets: inout PlanUtilizationHistoryBuckets) -> String?
    {
        let ownership = self.codexOwnershipContext(snapshot: snapshot, includeDashboardFallback: true)
        if let canonicalKey = ownership.canonicalKey {
            let resolvedAccountKey = self.materializeCodexPlanUtilizationHistoryIfNeeded(
                into: canonicalKey,
                ownership: ownership,
                shouldAdoptUnscopedHistory: shouldAdoptUnscopedHistory,
                providerBuckets: &providerBuckets)
            if shouldUpdatePreferredAccountKey {
                providerBuckets.preferredAccountKey = resolvedAccountKey
            }
            return resolvedAccountKey
        }

        if let stickyAccountKey = self.stickyPlanUtilizationAccountKey(providerBuckets: providerBuckets) {
            return stickyAccountKey
        }

        return nil
    }

    private func materializeCodexPlanUtilizationHistoryIfNeeded(
        into canonicalKey: String,
        ownership: CodexOwnershipContext,
        shouldAdoptUnscopedHistory: Bool,
        providerBuckets: inout PlanUtilizationHistoryBuckets) -> String
    {
        var historiesToMerge: [[PlanUtilizationSeriesHistory]] = []
        let scopedRawKeys = Array(providerBuckets.accounts.keys)
        var legacyRawKeysToRemove: [String] = []

        for rawKey in scopedRawKeys {
            let owner = CodexHistoryOwnership.classifyPersistedKey(
                rawKey,
                legacyEmailHash: ownership.planUtilizationLegacyEmailHash)
            let matchesTargetContinuity = CodexHistoryOwnership.belongsToTargetContinuity(
                owner,
                targetCanonicalKey: canonicalKey,
                canonicalEmailHashKey: ownership.canonicalEmailHashKey)
            if matchesTargetContinuity,
               let accountHistories = providerBuckets.accounts[rawKey],
               !accountHistories.isEmpty
            {
                historiesToMerge.append(accountHistories)
                if rawKey != canonicalKey {
                    legacyRawKeysToRemove.append(rawKey)
                }
            }
        }

        if let recoverableOpaqueRawKey = self.recoverableCodexOpaquePlanHistoryRawKey(
            targetCanonicalKey: canonicalKey,
            ownership: ownership,
            providerBuckets: providerBuckets),
            let opaqueHistories = providerBuckets.accounts[recoverableOpaqueRawKey],
            !opaqueHistories.isEmpty
        {
            historiesToMerge.append(opaqueHistories)
            legacyRawKeysToRemove.append(recoverableOpaqueRawKey)
        }

        if shouldAdoptUnscopedHistory,
           !providerBuckets.unscoped.isEmpty,
           CodexHistoryOwnership.hasStrictSingleAccountContinuity(
               scopedRawKeys: Self.scopedRawKeysRelevantToCodexUnscopedPlanHistory(providerBuckets),
               targetCanonicalKey: canonicalKey,
               canonicalEmailHashKey: ownership.canonicalEmailHashKey,
               legacyEmailHash: ownership.planUtilizationLegacyEmailHash,
               hasAdjacentMultiAccountVeto: ownership.hasAdjacentMultiAccountVeto)
        {
            historiesToMerge.append(providerBuckets.unscoped)
            providerBuckets.unscoped = []
        }

        guard !historiesToMerge.isEmpty else { return canonicalKey }
        for rawKey in legacyRawKeysToRemove {
            providerBuckets.accounts.removeValue(forKey: rawKey)
        }
        let mergedHistory = Self.mergedPlanUtilizationHistories(provider: .codex, histories: historiesToMerge)
        providerBuckets.setHistories(mergedHistory, for: canonicalKey)
        return canonicalKey
    }

    private func adoptPlanUtilizationUnscopedHistoryIfNeeded(
        into accountKey: String,
        provider: UsageProvider,
        providerBuckets: inout PlanUtilizationHistoryBuckets)
    {
        guard !providerBuckets.unscoped.isEmpty else { return }

        let existingHistory = providerBuckets.accounts[accountKey] ?? []
        let mergedHistory = Self.mergedPlanUtilizationHistories(provider: provider, histories: [
            existingHistory,
            providerBuckets.unscoped,
        ])
        providerBuckets.setHistories(mergedHistory, for: accountKey)
        providerBuckets.setHistories([], for: nil)
    }

    private func stickyPlanUtilizationAccountKey(
        providerBuckets: PlanUtilizationHistoryBuckets) -> String?
    {
        let knownAccountKeys = self.knownPlanUtilizationAccountKeys(providerBuckets: providerBuckets)
        guard !knownAccountKeys.isEmpty else { return nil }

        if let preferredAccountKey = providerBuckets.preferredAccountKey,
           knownAccountKeys.contains(preferredAccountKey)
        {
            return preferredAccountKey
        }

        if knownAccountKeys.count == 1 {
            return knownAccountKeys[0]
        }

        return knownAccountKeys.max { lhs, rhs in
            let lhsDate = providerBuckets.accounts[lhs]?.compactMap(\.latestCapturedAt).max() ?? .distantPast
            let rhsDate = providerBuckets.accounts[rhs]?.compactMap(\.latestCapturedAt).max() ?? .distantPast
            if lhsDate == rhsDate {
                return lhs > rhs
            }
            return lhsDate < rhsDate
        }
    }

    private func knownPlanUtilizationAccountKeys(providerBuckets: PlanUtilizationHistoryBuckets) -> [String] {
        providerBuckets.accounts.keys
            .sorted()
    }

    private func recoverableCodexOpaquePlanHistoryRawKey(
        targetCanonicalKey: String,
        ownership: CodexOwnershipContext,
        providerBuckets: PlanUtilizationHistoryBuckets) -> String?
    {
        guard !ownership.hasAdjacentMultiAccountVeto,
              let targetWeeklyResetAt = ownership.currentWeeklyResetAt
        else {
            return nil
        }

        let candidates = providerBuckets.accounts.compactMap { rawKey, histories -> String? in
            let owner = CodexHistoryOwnership.classifyPersistedKey(
                rawKey,
                legacyEmailHash: ownership.planUtilizationLegacyEmailHash)
            guard case .legacyOpaqueScoped = owner else { return nil }
            guard Self.isRecoverableCodexOpaquePlanHistory(
                histories,
                targetWeeklyResetAt: targetWeeklyResetAt)
            else {
                return nil
            }
            return rawKey
        }

        guard candidates.count == 1,
              let recoverableRawKey = candidates.first,
              let targetWeeklyResetAt = ownership.currentWeeklyResetAt
        else {
            return nil
        }

        guard !Self.hasConflictingScopedCodexPlanHistory(
            recoverableRawKey: recoverableRawKey,
            targetWeeklyResetAt: targetWeeklyResetAt,
            targetCanonicalKey: targetCanonicalKey,
            ownership: ownership,
            providerBuckets: providerBuckets)
        else {
            return nil
        }

        return recoverableRawKey
    }

    private nonisolated static func isRecoverableCodexOpaquePlanHistory(
        _ histories: [PlanUtilizationSeriesHistory],
        targetWeeklyResetAt: Date) -> Bool
    {
        guard let weekly = histories.first(where: { $0.name == .weekly && $0.windowMinutes == 10080 }),
              let session = histories.first(where: { $0.name == .session && $0.windowMinutes == 300 }),
              !session.entries.isEmpty
        else {
            return false
        }

        let distinctWeeklyResets = Set(weekly.entries.compactMap(\.resetsAt))
        guard distinctWeeklyResets.count >= 2 else { return false }
        guard weekly.entries.contains(where: { entry in
            Self.areEquivalentPlanUtilizationResetBoundaries(entry.resetsAt, targetWeeklyResetAt)
        }) else {
            return false
        }
        guard weekly.entries.contains(where: { entry in
            guard let reset = entry.resetsAt else { return false }
            return !Self.areEquivalentPlanUtilizationResetBoundaries(reset, targetWeeklyResetAt)
        }) else {
            return false
        }
        return true
    }

    private nonisolated static func areEquivalentPlanUtilizationResetBoundaries(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) < self.planUtilizationResetEquivalenceToleranceSeconds
    }

    private nonisolated static func scopedRawKeysRelevantToCodexUnscopedPlanHistory(
        _ providerBuckets: PlanUtilizationHistoryBuckets) -> [String]
    {
        guard let continuityWindow = self.planUtilizationContinuityWindow(for: providerBuckets) else {
            return []
        }

        return providerBuckets.accounts.compactMap { rawKey, histories in
            guard self.planUtilizationHistories(histories, overlap: continuityWindow) else {
                return nil
            }
            return rawKey
        }
    }

    private nonisolated static func planUtilizationContinuityWindow(
        for providerBuckets: PlanUtilizationHistoryBuckets) -> ClosedRange<Date>?
    {
        let capturedDates = providerBuckets.unscoped.flatMap(\.entries).map(\.capturedAt)
        guard let lowerBound = capturedDates.min(),
              let upperBound = capturedDates.max()
        else {
            return nil
        }
        let allHistories = providerBuckets.unscoped + providerBuckets.accounts.values.flatMap(\.self)
        let expansionMinutes = allHistories.map(\.windowMinutes).max() ?? 0
        let expansion = TimeInterval(expansionMinutes) * 60
        return lowerBound.addingTimeInterval(-expansion)...upperBound.addingTimeInterval(expansion)
    }

    private nonisolated static func planUtilizationHistories(
        _ histories: [PlanUtilizationSeriesHistory],
        overlap continuityWindow: ClosedRange<Date>) -> Bool
    {
        histories.contains { history in
            history.entries.contains { continuityWindow.contains($0.capturedAt) }
        }
    }

    private nonisolated static func hasConflictingScopedCodexPlanHistory(
        recoverableRawKey: String,
        targetWeeklyResetAt: Date,
        targetCanonicalKey: String,
        ownership: CodexOwnershipContext,
        providerBuckets: PlanUtilizationHistoryBuckets) -> Bool
    {
        providerBuckets.accounts.contains { rawKey, histories in
            guard rawKey != recoverableRawKey else { return false }
            guard self.historiesContainEquivalentWeeklyResetBoundary(
                histories,
                targetWeeklyResetAt: targetWeeklyResetAt)
            else {
                return false
            }

            let owner = CodexHistoryOwnership.classifyPersistedKey(
                rawKey,
                legacyEmailHash: ownership.planUtilizationLegacyEmailHash)
            switch owner {
            case .legacyOpaqueScoped:
                return false
            case .canonical, .legacyEmailHash:
                return !CodexHistoryOwnership.belongsToTargetContinuity(
                    owner,
                    targetCanonicalKey: targetCanonicalKey,
                    canonicalEmailHashKey: ownership.canonicalEmailHashKey)
            case .legacyUnscoped:
                return false
            }
        }
    }

    private nonisolated static func historiesContainEquivalentWeeklyResetBoundary(
        _ histories: [PlanUtilizationSeriesHistory],
        targetWeeklyResetAt: Date) -> Bool
    {
        histories.contains { history in
            history.entries.contains { entry in
                self.areEquivalentPlanUtilizationResetBoundaries(entry.resetsAt, targetWeeklyResetAt)
            }
        }
    }

    private nonisolated static func mergedPlanUtilizationHistories(
        provider _: UsageProvider,
        histories: [[PlanUtilizationSeriesHistory]]) -> [PlanUtilizationSeriesHistory]
    {
        var mergedByKey: [PlanUtilizationSeriesKey: PlanUtilizationSeriesHistory] = [:]

        for historyGroup in histories {
            for history in historyGroup {
                let key = PlanUtilizationSeriesKey(name: history.name, windowMinutes: history.windowMinutes)
                let existingEntries = mergedByKey[key]?.entries ?? []
                var mergedEntries = existingEntries
                for entry in history.entries.sorted(by: { $0.capturedAt < $1.capturedAt }) {
                    if let updatedEntries = self.updatedPlanUtilizationEntries(
                        existingEntries: mergedEntries,
                        entry: entry)
                    {
                        mergedEntries = updatedEntries
                    }
                }
                mergedByKey[key] = PlanUtilizationSeriesHistory(
                    name: history.name,
                    windowMinutes: history.windowMinutes,
                    entries: mergedEntries)
            }
        }

        return mergedByKey.values.sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes {
                return lhs.windowMinutes < rhs.windowMinutes
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
    }

    #if DEBUG
    nonisolated static func _planUtilizationAccountKeyForTesting(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> String?
    {
        self.planUtilizationIdentityAccountKey(provider: provider, snapshot: snapshot)
    }

    nonisolated static func _planUtilizationTokenAccountKeyForTesting(
        provider: UsageProvider,
        account: ProviderTokenAccount) -> String?
    {
        self.planUtilizationAccountKey(provider: provider, account: account)
    }

    nonisolated static func _codexLegacyPlanUtilizationEmailHashKeyForTesting(
        normalizedEmail: String) -> String
    {
        self.codexLegacyPlanUtilizationEmailHashKey(for: normalizedEmail)
    }
    #endif
}

actor PlanUtilizationHistoryPersistenceCoordinator {
    private let store: PlanUtilizationHistoryStore
    private var pendingSnapshot: [UsageProvider: PlanUtilizationHistoryBuckets]?
    private var isPersisting: Bool = false

    init(store: PlanUtilizationHistoryStore) {
        self.store = store
    }

    func enqueue(_ snapshot: [UsageProvider: PlanUtilizationHistoryBuckets]) {
        self.pendingSnapshot = snapshot
        guard !self.isPersisting else { return }
        self.isPersisting = true

        Task(priority: .utility) {
            await self.persistLoop()
        }
    }

    private func persistLoop() async {
        while let nextSnapshot = self.pendingSnapshot {
            self.pendingSnapshot = nil
            await self.saveAsync(nextSnapshot)
        }

        self.isPersisting = false
    }

    private func saveAsync(_ snapshot: [UsageProvider: PlanUtilizationHistoryBuckets]) async {
        let store = self.store
        await Task.detached(priority: .utility) {
            store.save(snapshot)
        }.value
    }
}
