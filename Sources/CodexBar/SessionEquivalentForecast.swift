import CodexBarCore
import Foundation

struct SessionEquivalentBurnEstimate: Equatable, Sendable {
    let medianWeeklyPercentPerWindow: Double
    let sampleCount: Int
}

struct SessionEquivalentForecast: Equatable, Sendable {
    static let sessionWindowMinutes = 300
    static let weeklyWindowMinutes = 10080
    static let resetTolerance: TimeInterval = 2 * 60

    let estimatedWindowsToExhaustWeekly: Double
    let windowsUntilReset: Int
    let availableWindowsUntilReset: Double
    let sampleCount: Int
    let weeklyResetsAt: Date
    let weeklyUsedPercent: Double
    let weeklyWindowID: String?

    init(
        estimatedWindowsToExhaustWeekly: Double,
        windowsUntilReset: Int,
        availableWindowsUntilReset: Double? = nil,
        sampleCount: Int,
        weeklyResetsAt: Date,
        weeklyUsedPercent: Double,
        weeklyWindowID: String? = nil)
    {
        self.estimatedWindowsToExhaustWeekly = estimatedWindowsToExhaustWeekly
        self.windowsUntilReset = windowsUntilReset
        self.availableWindowsUntilReset = availableWindowsUntilReset ?? Double(windowsUntilReset)
        self.sampleCount = sampleCount
        self.weeklyResetsAt = weeklyResetsAt
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyWindowID = weeklyWindowID
    }

    static func make(
        sessionWindow: RateWindow,
        weeklyWindow: RateWindow,
        burnEstimate: SessionEquivalentBurnEstimate,
        weeklyWindowID: String? = nil,
        now: Date,
        workDays: Int?,
        calendar: Calendar = .current) -> Self?
    {
        guard !sessionWindow.isSyntheticPlaceholder,
              sessionWindow.windowMinutes.map({ PlanUtilizationSeriesName.session.canonicalWindowMinutes($0) })
              == self.sessionWindowMinutes,
              weeklyWindow.windowMinutes.map({ PlanUtilizationSeriesName.weekly.canonicalWindowMinutes($0) })
              == self.weeklyWindowMinutes,
              let sessionResetsAt = sessionWindow.resetsAt,
              let weeklyResetsAt = weeklyWindow.resetsAt,
              weeklyWindow.usedPercent.isFinite,
              (0...100).contains(weeklyWindow.usedPercent),
              burnEstimate.medianWeeklyPercentPerWindow.isFinite,
              burnEstimate.medianWeeklyPercentPerWindow > 0,
              burnEstimate.sampleCount >= SessionEquivalentBurnEstimator.minimumSampleCount
        else {
            return nil
        }

        let sessionSeconds = TimeInterval(Self.sessionWindowMinutes * 60)
        let weeklySeconds = TimeInterval(Self.weeklyWindowMinutes * 60)
        let sessionRemaining = sessionResetsAt.timeIntervalSince(now)
        let weeklyRemaining = weeklyResetsAt.timeIntervalSince(now)
        guard sessionRemaining.isFinite,
              sessionRemaining > 0,
              sessionRemaining <= sessionSeconds + Self.resetTolerance,
              weeklyRemaining.isFinite,
              weeklyRemaining > 0,
              weeklyRemaining <= weeklySeconds + Self.resetTolerance
        else {
            return nil
        }

        let remainingWeeklyPercent = (100 - weeklyWindow.usedPercent).clamped(to: 0...100)
        guard remainingWeeklyPercent > 0 else { return nil }
        let estimatedWindows = remainingWeeklyPercent / burnEstimate.medianWeeklyPercentPerWindow
        guard estimatedWindows.isFinite, estimatedWindows >= 0 else { return nil }

        let remainingSeconds = Self.effectiveRemainingSeconds(
            from: now,
            to: weeklyResetsAt,
            workDays: workDays,
            calendar: calendar)
        guard remainingSeconds >= 0 else { return nil }
        let availableWindowsUntilReset = remainingSeconds / sessionSeconds
        let windowsUntilReset = Int(floor(availableWindowsUntilReset))

        return Self(
            estimatedWindowsToExhaustWeekly: estimatedWindows,
            windowsUntilReset: windowsUntilReset,
            availableWindowsUntilReset: availableWindowsUntilReset,
            sampleCount: burnEstimate.sampleCount,
            weeklyResetsAt: weeklyResetsAt,
            weeklyUsedPercent: weeklyWindow.usedPercent,
            weeklyWindowID: weeklyWindowID)
    }

    func applies(to weeklyWindow: RateWindow, windowID: String?) -> Bool {
        guard weeklyWindow.windowMinutes.map({ PlanUtilizationSeriesName.weekly.canonicalWindowMinutes($0) })
            == Self.weeklyWindowMinutes,
            let resetsAt = weeklyWindow.resetsAt
        else {
            return false
        }
        return self.weeklyWindowID == windowID
            && abs(resetsAt.timeIntervalSince(self.weeklyResetsAt)) < 2 * 60
            && abs(weeklyWindow.usedPercent - self.weeklyUsedPercent) < 0.001
    }

    private static func effectiveRemainingSeconds(
        from now: Date,
        to resetsAt: Date,
        workDays: Int?,
        calendar: Calendar) -> TimeInterval
    {
        let wallClockSeconds = max(0, resetsAt.timeIntervalSince(now))
        guard let workDays, workDays >= 2, workDays < 7 else { return wallClockSeconds }

        var workSeconds: TimeInterval = 0
        var cursor = now
        while cursor < resetsAt {
            guard let nextDay = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: cursor)),
                nextDay > cursor
            else {
                return wallClockSeconds
            }
            let sliceEnd = min(nextDay, resetsAt)
            if Self.isWorkday(cursor, workDays: workDays, calendar: calendar) {
                workSeconds += sliceEnd.timeIntervalSince(cursor)
            }
            cursor = sliceEnd
        }
        return workSeconds
    }

    private static func isWorkday(_ date: Date, workDays: Int, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let isoWeekday = weekday == 1 ? 7 : weekday - 1
        return isoWeekday <= workDays
    }
}

enum SessionEquivalentBurnEstimator {
    static let defaultSampleLimit = 7
    static let minimumSampleCount = 3
    private static let observationAlignmentTolerance: TimeInterval = 0
    private static let resetEquivalenceTolerance = SessionEquivalentForecast.resetTolerance

    private struct SessionGroup {
        let resetsAt: Date
        var entries: [PlanUtilizationHistoryEntry]
        var maximumUsedPercent: Double
    }

    private struct BurnObservation {
        let sessionUsedPercent: Double
        let weeklyEntry: PlanUtilizationHistoryEntry
    }

    static func estimate(
        histories: [PlanUtilizationSeriesHistory],
        currentSessionResetsAt: Date,
        now: Date,
        sampleLimit: Int = Self.defaultSampleLimit) -> SessionEquivalentBurnEstimate?
    {
        guard sampleLimit > 0,
              let sessionHistory = histories.first(where: {
                  $0.name == .session
                      && $0.name.canonicalWindowMinutes($0.windowMinutes)
                      == SessionEquivalentForecast.sessionWindowMinutes
              }),
              let weeklyHistory = histories.first(where: {
                  $0.name == .weekly
                      && $0.name.canonicalWindowMinutes($0.windowMinutes)
                      == SessionEquivalentForecast.weeklyWindowMinutes
              })
        else {
            return nil
        }

        let sessionDuration = TimeInterval(SessionEquivalentForecast.sessionWindowMinutes * 60)
        let weeklyDuration = TimeInterval(SessionEquivalentForecast.weeklyWindowMinutes * 60)
        let currentSessionRemaining = currentSessionResetsAt.timeIntervalSince(now)
        guard currentSessionRemaining.isFinite,
              currentSessionRemaining > 0,
              currentSessionRemaining <= sessionDuration + Self.resetEquivalenceTolerance,
              Self.isChronologicallyOrdered(sessionHistory.entries),
              Self.isChronologicallyOrdered(weeklyHistory.entries)
        else {
            return nil
        }

        var groups: [SessionGroup] = []
        groups.reserveCapacity(sessionHistory.entries.count)
        for entry in sessionHistory.entries {
            guard entry.usedPercent.isFinite,
                  (0...100).contains(entry.usedPercent),
                  let resetsAt = entry.resetsAt,
                  Self.isPlausibleReset(
                      resetsAt,
                      capturedAt: entry.capturedAt,
                      duration: sessionDuration)
            else {
                continue
            }
            if let lastIndex = groups.indices.last,
               abs(groups[lastIndex].resetsAt.timeIntervalSince(resetsAt)) <= Self.resetEquivalenceTolerance
            {
                groups[lastIndex].entries.append(entry)
                groups[lastIndex].maximumUsedPercent = max(groups[lastIndex].maximumUsedPercent, entry.usedPercent)
            } else {
                guard groups.last.map({ $0.resetsAt <= resetsAt }) ?? true else { return nil }
                groups.append(SessionGroup(
                    resetsAt: resetsAt,
                    entries: [entry],
                    maximumUsedPercent: entry.usedPercent))
            }
        }

        let completedActiveGroups = groups.reversed().compactMap { group -> SessionGroup? in
            guard group.resetsAt < currentSessionResetsAt.addingTimeInterval(-Self.resetEquivalenceTolerance),
                  group.resetsAt <= now,
                  group.maximumUsedPercent > 0
            else {
                return nil
            }
            return group
        }

        let weeklyEntries = weeklyHistory.entries.filter { entry in
            entry.usedPercent.isFinite
                && (0...100).contains(entry.usedPercent)
                && entry.resetsAt.map {
                    Self.isPlausibleReset($0, capturedAt: entry.capturedAt, duration: weeklyDuration)
                } == true
        }
        guard !weeklyEntries.isEmpty else { return nil }

        var burns: [Double] = []
        let candidateGroups = completedActiveGroups.prefix(sampleLimit)
        burns.reserveCapacity(candidateGroups.count)
        for group in candidateGroups {
            guard let fullAllowanceBurn = Self.normalizedBurn(
                for: group,
                weeklyEntries: weeklyEntries,
                sessionDuration: sessionDuration)
            else { continue }
            burns.append(fullAllowanceBurn)
        }

        guard burns.count >= Self.minimumSampleCount else { return nil }
        burns.sort()
        let middle = burns.count / 2
        let median = burns.count.isMultiple(of: 2)
            ? (burns[middle - 1] + burns[middle]) / 2
            : burns[middle]
        guard median.isFinite, median > 0 else { return nil }
        return SessionEquivalentBurnEstimate(
            medianWeeklyPercentPerWindow: median,
            sampleCount: burns.count)
    }

    private static func normalizedBurn(
        for group: SessionGroup,
        weeklyEntries: [PlanUtilizationHistoryEntry],
        sessionDuration: TimeInterval) -> Double?
    {
        guard let firstSessionEntry = group.entries.first,
              let lastSessionEntry = group.entries.last
        else {
            return nil
        }

        var observations: [BurnObservation] = []
        let windowStart = group.resetsAt.addingTimeInterval(-sessionDuration)
        if let weeklyStart = Self.nearestEntry(
            to: windowStart,
            entries: weeklyEntries,
            tolerance: Self.resetEquivalenceTolerance,
            requireNotAfterTarget: true),
            weeklyStart.capturedAt <= windowStart,
            weeklyStart.capturedAt < firstSessionEntry.capturedAt
        {
            observations.append(BurnObservation(sessionUsedPercent: 0, weeklyEntry: weeklyStart))
        }

        for sessionEntry in group.entries {
            guard let weeklyEntry = Self.nearestEntry(
                to: sessionEntry.capturedAt,
                entries: weeklyEntries,
                tolerance: Self.observationAlignmentTolerance)
            else {
                continue
            }
            observations.append(BurnObservation(
                sessionUsedPercent: sessionEntry.usedPercent,
                weeklyEntry: weeklyEntry))
        }

        if group.maximumUsedPercent >= 100,
           let weeklyEnd = Self.nearestEntry(
               to: group.resetsAt,
               entries: weeklyEntries,
               tolerance: Self.resetEquivalenceTolerance,
               requireNotAfterTarget: true),
           weeklyEnd.capturedAt <= group.resetsAt,
           lastSessionEntry.capturedAt < weeklyEnd.capturedAt
        {
            observations.append(BurnObservation(sessionUsedPercent: 100, weeklyEntry: weeklyEnd))
        }

        observations.sort { lhs, rhs in
            if lhs.weeklyEntry.capturedAt != rhs.weeklyEntry.capturedAt {
                return lhs.weeklyEntry.capturedAt < rhs.weeklyEntry.capturedAt
            }
            return lhs.sessionUsedPercent < rhs.sessionUsedPercent
        }
        guard let start = observations.first,
              let end = observations.last,
              start.weeklyEntry.capturedAt < end.weeklyEntry.capturedAt,
              let startReset = start.weeklyEntry.resetsAt,
              let endReset = end.weeklyEntry.resetsAt,
              abs(startReset.timeIntervalSince(endReset)) <= Self.resetEquivalenceTolerance
        else {
            return nil
        }

        let sessionConsumption = end.sessionUsedPercent - start.sessionUsedPercent
        let weeklyBurn = end.weeklyEntry.usedPercent - start.weeklyEntry.usedPercent
        guard sessionConsumption.isFinite,
              sessionConsumption > 0,
              weeklyBurn.isFinite,
              weeklyBurn > 0
        else {
            return nil
        }
        let fullAllowanceBurn = 100 * weeklyBurn / sessionConsumption
        guard fullAllowanceBurn.isFinite, fullAllowanceBurn > 0 else { return nil }
        return fullAllowanceBurn
    }

    private static func nearestEntry(
        to target: Date,
        entries: [PlanUtilizationHistoryEntry],
        tolerance: TimeInterval,
        requireNotAfterTarget: Bool = false) -> PlanUtilizationHistoryEntry?
    {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entries[middle].capturedAt < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var candidates: [PlanUtilizationHistoryEntry] = []
        if lower < entries.count {
            candidates.append(entries[lower])
        }
        if lower > 0 {
            candidates.append(entries[lower - 1])
        }
        return candidates
            .filter { !requireNotAfterTarget || $0.capturedAt <= target }
            .filter { abs($0.capturedAt.timeIntervalSince(target)) <= tolerance }
            .min { lhs, rhs in
                abs(lhs.capturedAt.timeIntervalSince(target)) < abs(rhs.capturedAt.timeIntervalSince(target))
            }
    }

    private static func isChronologicallyOrdered(_ entries: [PlanUtilizationHistoryEntry]) -> Bool {
        guard entries.allSatisfy(\.capturedAt.timeIntervalSinceReferenceDate.isFinite) else { return false }
        return zip(entries, entries.dropFirst()).allSatisfy { pair in
            pair.0.capturedAt <= pair.1.capturedAt
        }
    }

    private static func isPlausibleReset(
        _ resetsAt: Date,
        capturedAt: Date,
        duration: TimeInterval) -> Bool
    {
        let remaining = resetsAt.timeIntervalSince(capturedAt)
        return remaining.isFinite
            && remaining >= -Self.resetEquivalenceTolerance
            && remaining <= duration + Self.resetEquivalenceTolerance
    }
}

private struct SessionEquivalentBurnCacheKey: Equatable {
    let historyRevision: Int
    let historySelectionIdentity: String
    let currentSessionResetsAt: Date
    let weeklyWindowID: String?
}

struct SessionEquivalentBurnCacheEntry {
    fileprivate let key: SessionEquivalentBurnCacheKey
    fileprivate let estimate: SessionEquivalentBurnEstimate?
}

@MainActor
extension UsageStore {
    func sessionEquivalentForecast(
        provider: UsageProvider,
        sessionWindow: RateWindow,
        weeklyWindow: RateWindow,
        weeklyWindowID: String? = nil,
        historyIdentity: String? = nil,
        historySelection: PlanUtilizationHistorySelection? = nil,
        now: Date = .init()) -> SessionEquivalentForecast?
    {
        guard sessionWindow.windowMinutes.map({ PlanUtilizationSeriesName.session.canonicalWindowMinutes($0) })
            == SessionEquivalentForecast.sessionWindowMinutes,
            let currentSessionResetsAt = sessionWindow.resetsAt,
            currentSessionResetsAt.timeIntervalSinceReferenceDate.isFinite
        else {
            return nil
        }

        let selection = historySelection ?? self.planUtilizationHistorySelection(for: provider)
        guard self.sessionEquivalentHistoryIdentityMatches(
            provider: provider,
            accountKey: selection.accountKey,
            historyIdentity: historyIdentity)
        else {
            return nil
        }
        let cacheKey = SessionEquivalentBurnCacheKey(
            historyRevision: self.planUtilizationHistoryRevision,
            historySelectionIdentity: selection.cacheIdentity,
            currentSessionResetsAt: currentSessionResetsAt,
            weeklyWindowID: weeklyWindowID)
        let burnEstimate: SessionEquivalentBurnEstimate?
        if let cached = self.sessionEquivalentBurnCache[provider], cached.key == cacheKey {
            burnEstimate = cached.estimate
        } else {
            burnEstimate = SessionEquivalentBurnEstimator.estimate(
                histories: selection.histories,
                currentSessionResetsAt: currentSessionResetsAt,
                now: now)
            self.sessionEquivalentHistoryScanCount &+= 1
            self.sessionEquivalentBurnCache[provider] = SessionEquivalentBurnCacheEntry(
                key: cacheKey,
                estimate: burnEstimate)
        }

        guard let burnEstimate else { return nil }
        return SessionEquivalentForecast.make(
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            burnEstimate: burnEstimate,
            weeklyWindowID: weeklyWindowID,
            now: now,
            workDays: self.settings.weeklyProgressWorkDays)
    }

    #if DEBUG
    var _sessionEquivalentHistoryScanCountForTesting: Int {
        self.sessionEquivalentHistoryScanCount
    }
    #endif
}
