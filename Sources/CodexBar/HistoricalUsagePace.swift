import CodexBarCore
import Foundation

enum HistoricalUsageWindowKind: String, Codable, Sendable {
    case secondary
}

enum HistoricalUsageRecordSource: String, Codable, Sendable {
    case live
    case backfill
}

struct HistoricalUsageRecord: Codable, Sendable {
    let v: Int
    let provider: UsageProvider
    let windowKind: HistoricalUsageWindowKind
    let source: HistoricalUsageRecordSource
    let accountKey: String?
    let sampledAt: Date
    let usedPercent: Double
    let resetsAt: Date
    let windowMinutes: Int

    init(
        v: Int,
        provider: UsageProvider,
        windowKind: HistoricalUsageWindowKind,
        source: HistoricalUsageRecordSource,
        accountKey: String?,
        sampledAt: Date,
        usedPercent: Double,
        resetsAt: Date,
        windowMinutes: Int)
    {
        self.v = v
        self.provider = provider
        self.windowKind = windowKind
        self.source = source
        self.accountKey = accountKey
        self.sampledAt = sampledAt
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
        self.provider = try container.decode(UsageProvider.self, forKey: .provider)
        self.windowKind = try container.decode(HistoricalUsageWindowKind.self, forKey: .windowKind)
        self.source = try container.decodeIfPresent(HistoricalUsageRecordSource.self, forKey: .source) ?? .live
        self.accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
        self.sampledAt = try container.decode(Date.self, forKey: .sampledAt)
        self.usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        self.resetsAt = try container.decode(Date.self, forKey: .resetsAt)
        self.windowMinutes = try container.decode(Int.self, forKey: .windowMinutes)
    }
}

struct HistoricalWeekProfile: Sendable {
    let resetsAt: Date
    let windowMinutes: Int
    let curve: [Double]
}

struct CodexHistoricalDataset: Sendable {
    static let gridPointCount = 169
    let weeks: [HistoricalWeekProfile]
}

actor HistoricalUsageHistoryStore {
    private static let schemaVersion = 1
    private static let writeInterval: TimeInterval = 30 * 60
    private static let writeDeltaThreshold: Double = 1
    private static let retentionDays: TimeInterval = 56 * 24 * 60 * 60
    private static let minimumWeekSamples = 6
    private static let boundaryCoverageWindow: TimeInterval = 24 * 60 * 60
    private static let backfillWindowCapWeeks = 8
    private static let backfillCalibrationMinimumUsedPercent = 1.0
    private static let backfillCalibrationMinimumCredits = 0.001
    private static let backfillSampleFractions: [Double] = (0...14).map { Double($0) / 14.0 }
    private static let coverageTolerance: TimeInterval = 16 * 60 * 60
    private static let resetBucketSeconds: TimeInterval = 60

    private let fileURL: URL
    private var records: [HistoricalUsageRecord] = []
    private var loaded = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? HistoricalUsageHistoryStore.defaultFileURL()
    }

    func loadCodexDataset(accountKey: String?) -> CodexHistoricalDataset? {
        self.ensureLoaded()
        return self.buildDataset(accountKey: accountKey)
    }

    func recordCodexWeekly(
        window: RateWindow,
        sampledAt: Date = .init(),
        accountKey: String?) -> CodexHistoricalDataset?
    {
        guard let rawResetsAt = window.resetsAt else { return self.loadCodexDataset(accountKey: accountKey) }
        guard let windowMinutes = window.windowMinutes, windowMinutes > 0 else {
            return self.loadCodexDataset(accountKey: accountKey)
        }
        self.ensureLoaded()
        let resetsAt = Self.normalizeReset(rawResetsAt)

        let sample = HistoricalUsageRecord(
            v: Self.schemaVersion,
            provider: .codex,
            windowKind: .secondary,
            source: .live,
            accountKey: accountKey,
            sampledAt: sampledAt,
            usedPercent: Self.clamp(window.usedPercent, lower: 0, upper: 100),
            resetsAt: resetsAt,
            windowMinutes: windowMinutes)

        if !self.shouldAccept(sample) {
            return self.buildDataset(accountKey: accountKey)
        }

        self.records.append(sample)
        self.pruneOldRecords(now: sampledAt)
        self.records.sort { lhs, rhs in
            if lhs.sampledAt == rhs.sampledAt {
                if lhs.resetsAt == rhs.resetsAt {
                    return lhs.usedPercent < rhs.usedPercent
                }
                return lhs.resetsAt < rhs.resetsAt
            }
            return lhs.sampledAt < rhs.sampledAt
        }
        self.persist()
        return self.buildDataset(accountKey: accountKey)
    }

    func backfillCodexWeeklyFromUsageBreakdown(
        _ breakdown: [OpenAIDashboardDailyBreakdown],
        referenceWindow: RateWindow,
        now: Date = .init(),
        accountKey: String?) -> CodexHistoricalDataset?
    {
        self.ensureLoaded()
        let existingDataset = self.buildDataset(accountKey: accountKey)

        guard let rawResetsAt = referenceWindow.resetsAt else { return existingDataset }
        guard let windowMinutes = referenceWindow.windowMinutes, windowMinutes > 0 else { return existingDataset }
        let resetsAt = Self.normalizeReset(rawResetsAt)

        let duration = TimeInterval(windowMinutes) * 60
        guard duration > 0 else { return existingDataset }

        let windowStart = resetsAt.addingTimeInterval(-duration)
        let calibrationEnd = Self.clampDate(now, lower: windowStart, upper: resetsAt)
        let dayUsages = Self.parseDayUsages(from: breakdown, asOf: calibrationEnd)
        guard !dayUsages.isEmpty else { return existingDataset }
        guard let coverageStart = dayUsages.first?.start, let coverageEnd = dayUsages.last?.end else {
            return existingDataset
        }
        guard coverageStart <= windowStart.addingTimeInterval(Self.coverageTolerance) else {
            return existingDataset
        }
        guard coverageEnd >= calibrationEnd.addingTimeInterval(-Self.coverageTolerance) else {
            return existingDataset
        }

        let currentUsedPercent = Self.clamp(referenceWindow.usedPercent, lower: 0, upper: 100)
        guard currentUsedPercent >= Self.backfillCalibrationMinimumUsedPercent else { return existingDataset }

        let currentCredits = Self.creditsUsed(
            from: dayUsages,
            between: windowStart,
            and: calibrationEnd)
        guard currentCredits > Self.backfillCalibrationMinimumCredits else { return existingDataset }

        let estimatedCreditsAtLimit = currentCredits / (currentUsedPercent / 100)
        guard estimatedCreditsAtLimit.isFinite, estimatedCreditsAtLimit > Self.backfillCalibrationMinimumCredits else {
            return existingDataset
        }

        struct RecordKey: Hashable {
            let resetsAt: Date
            let sampledAt: Date
            let windowMinutes: Int
            let accountKey: String?
        }

        var synthesized: [HistoricalUsageRecord] = []
        synthesized.reserveCapacity(Self.backfillWindowCapWeeks * Self.backfillSampleFractions.count)

        for weeksBack in 1...Self.backfillWindowCapWeeks {
            let reset = Self.normalizeReset(resetsAt.addingTimeInterval(-duration * Double(weeksBack)))
            let start = reset.addingTimeInterval(-duration)
            guard start >= coverageStart.addingTimeInterval(-Self.coverageTolerance),
                  reset <= coverageEnd.addingTimeInterval(Self.coverageTolerance)
            else {
                continue
            }

            let existingForWeek = self.records.filter {
                $0.provider == .codex &&
                    $0.windowKind == .secondary &&
                    $0.windowMinutes == windowMinutes &&
                    $0.accountKey == accountKey &&
                    $0.resetsAt == reset
            }
            if Self.isCompleteWeek(samples: existingForWeek, windowStart: start, resetsAt: reset) {
                continue
            }
            var existingRecordKeys = Set(existingForWeek.map {
                RecordKey(
                    resetsAt: $0.resetsAt,
                    sampledAt: $0.sampledAt,
                    windowMinutes: $0.windowMinutes,
                    accountKey: $0.accountKey)
            })

            let weekCredits = Self.creditsUsed(from: dayUsages, between: start, and: reset)
            guard weekCredits > Self.backfillCalibrationMinimumCredits else { continue }

            for fraction in Self.backfillSampleFractions {
                let sampledAt = start.addingTimeInterval(duration * fraction)
                let recordKey = RecordKey(
                    resetsAt: reset,
                    sampledAt: sampledAt,
                    windowMinutes: windowMinutes,
                    accountKey: accountKey)
                guard !existingRecordKeys.contains(recordKey) else { continue }
                let cumulativeCredits = Self.creditsUsed(from: dayUsages, between: start, and: sampledAt)
                let usedPercent = Self.clamp((cumulativeCredits / estimatedCreditsAtLimit) * 100, lower: 0, upper: 100)
                synthesized.append(HistoricalUsageRecord(
                    v: Self.schemaVersion,
                    provider: .codex,
                    windowKind: .secondary,
                    source: .backfill,
                    accountKey: accountKey,
                    sampledAt: sampledAt,
                    usedPercent: usedPercent,
                    resetsAt: reset,
                    windowMinutes: windowMinutes))
                existingRecordKeys.insert(recordKey)
            }
        }

        guard !synthesized.isEmpty else { return existingDataset }
        self.records.append(contentsOf: synthesized)
        self.pruneOldRecords(now: now)
        self.records.sort { lhs, rhs in
            if lhs.sampledAt == rhs.sampledAt {
                if lhs.resetsAt == rhs.resetsAt {
                    return lhs.usedPercent < rhs.usedPercent
                }
                return lhs.resetsAt < rhs.resetsAt
            }
            return lhs.sampledAt < rhs.sampledAt
        }
        self.persist()
        return self.buildDataset(accountKey: accountKey)
    }

    private func shouldAccept(_ sample: HistoricalUsageRecord) -> Bool {
        guard let prior = self.records
            .last(where: {
                $0.provider == sample.provider &&
                    $0.windowKind == sample.windowKind &&
                    $0.accountKey == sample.accountKey &&
                    $0.windowMinutes == sample.windowMinutes
            })
        else {
            return true
        }

        if prior.resetsAt != sample.resetsAt { return true }
        if sample.sampledAt.timeIntervalSince(prior.sampledAt) >= Self.writeInterval { return true }
        if abs(sample.usedPercent - prior.usedPercent) >= Self.writeDeltaThreshold { return true }
        return false
    }

    private func pruneOldRecords(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retentionDays)
        self.records.removeAll { $0.sampledAt < cutoff }
    }

    private func ensureLoaded() {
        guard !self.loaded else { return }
        self.loaded = true
        self.records = self.readRecordsFromDisk()
        self.pruneOldRecords(now: .init())
    }

    private func readRecordsFromDisk() -> [HistoricalUsageRecord] {
        guard let data = try? Data(contentsOf: self.fileURL), !data.isEmpty else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decoded: [HistoricalUsageRecord] = []
        decoded.reserveCapacity(text.count / 80)

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            guard var record = try? decoder.decode(HistoricalUsageRecord.self, from: lineData) else { continue }
            record = HistoricalUsageRecord(
                v: record.v,
                provider: record.provider,
                windowKind: record.windowKind,
                source: record.source,
                accountKey: record.accountKey?.isEmpty == false ? record.accountKey : nil,
                sampledAt: record.sampledAt,
                usedPercent: Self.clamp(record.usedPercent, lower: 0, upper: 100),
                resetsAt: Self.normalizeReset(record.resetsAt),
                windowMinutes: record.windowMinutes)
            decoded.append(record)
        }
        return decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        var lines: [String] = []
        lines.reserveCapacity(self.records.count)
        for record in self.records {
            guard let data = try? encoder.encode(record),
                  let line = String(data: data, encoding: .utf8)
            else {
                continue
            }
            lines.append(line)
        }

        let payload = (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        let directory = self.fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try payload.write(to: self.fileURL, options: [.atomic])
        } catch {
            // Best-effort cache file; ignore write failures.
        }
    }

    private func buildDataset(accountKey: String?) -> CodexHistoricalDataset? {
        struct WeekKey: Hashable {
            let resetsAt: Date
            let windowMinutes: Int
        }

        let scoped = self.records
            .filter { record in
                guard record.provider == .codex, record.windowKind == .secondary, record.windowMinutes > 0 else {
                    return false
                }
                if let accountKey {
                    return record.accountKey == accountKey
                }
                return record.accountKey == nil
            }
        if scoped.isEmpty { return nil }

        let grouped = Dictionary(grouping: scoped) {
            WeekKey(resetsAt: $0.resetsAt, windowMinutes: $0.windowMinutes)
        }

        var weeks: [HistoricalWeekProfile] = []
        weeks.reserveCapacity(grouped.count)

        for (key, samples) in grouped {
            let duration = TimeInterval(key.windowMinutes) * 60
            guard duration > 0 else { continue }
            let windowStart = key.resetsAt.addingTimeInterval(-duration)
            guard Self.isCompleteWeek(samples: samples, windowStart: windowStart, resetsAt: key.resetsAt) else {
                continue
            }

            guard let curve = Self.reconstructWeekCurve(
                samples: samples,
                windowStart: windowStart,
                windowDuration: duration,
                gridPointCount: CodexHistoricalDataset.gridPointCount)
            else {
                continue
            }

            weeks.append(HistoricalWeekProfile(
                resetsAt: key.resetsAt,
                windowMinutes: key.windowMinutes,
                curve: curve))
        }

        weeks.sort { $0.resetsAt < $1.resetsAt }
        if weeks.isEmpty { return nil }
        return CodexHistoricalDataset(weeks: weeks)
    }

    private static func reconstructWeekCurve(
        samples: [HistoricalUsageRecord],
        windowStart: Date,
        windowDuration: TimeInterval,
        gridPointCount: Int) -> [Double]?
    {
        guard gridPointCount >= 2 else { return nil }

        var points = samples.map { sample -> (u: Double, value: Double) in
            let offset = sample.sampledAt.timeIntervalSince(windowStart)
            let u = Self.clamp(offset / windowDuration, lower: 0, upper: 1)
            return (u: u, value: Self.clamp(sample.usedPercent, lower: 0, upper: 100))
        }
        points.sort { lhs, rhs in
            if lhs.u == rhs.u {
                return lhs.value < rhs.value
            }
            return lhs.u < rhs.u
        }

        guard !points.isEmpty else { return nil }

        // Enforce monotonicity on observed samples before interpolation.
        var monotonePoints: [(u: Double, value: Double)] = []
        monotonePoints.reserveCapacity(points.count)
        var runningMax = 0.0
        for point in points {
            runningMax = max(runningMax, point.value)
            monotonePoints.append((u: point.u, value: runningMax))
        }

        // Anchor reconstructed curves to reset start and end-of-week plateau.
        let endValue = monotonePoints.last?.value ?? 0
        monotonePoints.append((u: 0, value: 0))
        monotonePoints.append((u: 1, value: endValue))
        monotonePoints.sort { lhs, rhs in
            if lhs.u == rhs.u {
                return lhs.value < rhs.value
            }
            return lhs.u < rhs.u
        }
        runningMax = 0
        for index in monotonePoints.indices {
            runningMax = max(runningMax, monotonePoints[index].value)
            monotonePoints[index].value = runningMax
        }

        var curve = Array(repeating: 0.0, count: gridPointCount)
        let first = monotonePoints[0]
        let last = monotonePoints[monotonePoints.count - 1]

        var upperIndex = 1
        let denominator = Double(gridPointCount - 1)

        for index in 0..<gridPointCount {
            let u = Double(index) / denominator
            if u <= first.u {
                curve[index] = first.value
                continue
            }
            if u >= last.u {
                curve[index] = last.value
                continue
            }

            while upperIndex < monotonePoints.count, monotonePoints[upperIndex].u < u {
                upperIndex += 1
            }

            let hi = monotonePoints[min(upperIndex, monotonePoints.count - 1)]
            let lo = monotonePoints[max(0, upperIndex - 1)]
            if hi.u <= lo.u {
                curve[index] = max(lo.value, hi.value)
                continue
            }

            let ratio = Self.clamp((u - lo.u) / (hi.u - lo.u), lower: 0, upper: 1)
            curve[index] = lo.value + (hi.value - lo.value) * ratio
        }

        // Re-enforce monotonicity on reconstructed grid.
        var curveMax = 0.0
        for index in curve.indices {
            curve[index] = Self.clamp(curve[index], lower: 0, upper: 100)
            curveMax = max(curveMax, curve[index])
            curve[index] = curveMax
        }
        return curve
    }

    private static func isCompleteWeek(samples: [HistoricalUsageRecord], windowStart: Date, resetsAt: Date) -> Bool {
        guard samples.count >= self.minimumWeekSamples else { return false }
        let startBoundary = windowStart.addingTimeInterval(Self.boundaryCoverageWindow)
        let endBoundary = resetsAt.addingTimeInterval(-Self.boundaryCoverageWindow)
        let hasStartCoverage = samples.contains { sample in
            sample.sampledAt >= windowStart && sample.sampledAt <= startBoundary
        }
        let hasEndCoverage = samples.contains { sample in
            sample.sampledAt >= endBoundary && sample.sampledAt <= resetsAt
        }
        return hasStartCoverage && hasEndCoverage
    }

    private struct DayUsage {
        let start: Date
        let end: Date
        let creditsUsed: Double
    }

    private static func parseDayUsages(from breakdown: [OpenAIDashboardDailyBreakdown], asOf: Date) -> [DayUsage] {
        var creditsByStart: [Date: Double] = [:]
        creditsByStart.reserveCapacity(breakdown.count)

        for day in breakdown {
            guard let dayStart = Self.dayStart(for: day.day) else { continue }
            creditsByStart[dayStart, default: 0] += max(0, day.totalCreditsUsed)
        }

        let calendar = Self.gregorianCalendar()
        var dayUsages: [DayUsage] = []
        dayUsages.reserveCapacity(creditsByStart.count)
        for (dayStart, credits) in creditsByStart {
            guard let nominalEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let effectiveEnd: Date = if dayStart <= asOf, asOf < nominalEnd {
                asOf
            } else {
                nominalEnd
            }
            guard effectiveEnd > dayStart else { continue }
            dayUsages.append(DayUsage(start: dayStart, end: effectiveEnd, creditsUsed: credits))
        }

        dayUsages.sort { lhs, rhs in lhs.start < rhs.start }
        return dayUsages
    }

    private static func dayStart(for key: String) -> Date? {
        let components = key.split(separator: "-", omittingEmptySubsequences: true)
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2])
        else {
            return nil
        }

        let calendar = Self.gregorianCalendar()
        var dateComponents = DateComponents()
        dateComponents.calendar = calendar
        dateComponents.timeZone = calendar.timeZone
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = day
        dateComponents.hour = 0
        dateComponents.minute = 0
        dateComponents.second = 0
        return dateComponents.date
    }

    private static func creditsUsed(from dayUsages: [DayUsage], between start: Date, and end: Date) -> Double {
        guard end > start else { return 0 }
        var total = 0.0
        for day in dayUsages {
            if day.end <= start { continue }
            if day.start >= end { break }
            let overlapStart = max(day.start, start)
            let overlapEnd = min(day.end, end)
            guard overlapEnd > overlapStart else { continue }

            let dayDuration = day.end.timeIntervalSince(day.start)
            guard dayDuration > 0 else { continue }
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            total += day.creditsUsed * (overlap / dayDuration)
        }
        return max(0, total)
    }

    nonisolated static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("usage-history.jsonl", isDirectory: false)
    }

    private nonisolated static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }

    private nonisolated static func clampDate(_ value: Date, lower: Date, upper: Date) -> Date {
        min(upper, max(lower, value))
    }

    private nonisolated static func normalizeReset(_ value: Date) -> Date {
        let bucket = Self.resetBucketSeconds
        guard bucket > 0 else { return value }
        let rounded = (value.timeIntervalSinceReferenceDate / bucket).rounded() * bucket
        return Date(timeIntervalSinceReferenceDate: rounded)
    }

    private nonisolated static func gregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }

    #if DEBUG
    nonisolated static func _dayStartForTesting(_ key: String) -> Date? {
        self.dayStart(for: key)
    }

    nonisolated static func _creditsUsedForTesting(
        breakdown: [OpenAIDashboardDailyBreakdown],
        asOf: Date,
        start: Date,
        end: Date) -> Double
    {
        let dayUsages = Self.parseDayUsages(from: breakdown, asOf: asOf)
        return Self.creditsUsed(from: dayUsages, between: start, and: end)
    }
    #endif
}

enum CodexHistoricalPaceEvaluator {
    static let minimumCompleteWeeksForHistorical = 3
    static let minimumWeeksForRisk = 5
    private static let recencyTauWeeks: Double = 3
    private static let epsilon: Double = 1e-9
    private static let resetBucketSeconds: TimeInterval = 60

    static func evaluate(window: RateWindow, now: Date, dataset: CodexHistoricalDataset?) -> UsagePace? {
        guard let dataset else { return nil }
        guard let resetsAt = window.resetsAt else { return nil }
        let minutes = window.windowMinutes ?? 10080
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        guard duration > 0 else { return nil }

        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0, timeUntilReset <= duration else { return nil }
        let normalizedResetsAt = Self.normalizeReset(resetsAt)

        let elapsed = Self.clamp(duration - timeUntilReset, lower: 0, upper: duration)
        let actual = Self.clamp(window.usedPercent, lower: 0, upper: 100)
        if elapsed == 0, actual > 0 { return nil }

        let uNow = Self.clamp(elapsed / duration, lower: 0, upper: 1)
        let scopedWeeks = dataset.weeks.filter { week in
            week.windowMinutes == minutes && week.resetsAt < normalizedResetsAt
        }
        guard scopedWeeks.count >= Self.minimumCompleteWeeksForHistorical else { return nil }

        let weightedWeeks = scopedWeeks.map { week in
            let ageWeeks = Self.clamp(
                normalizedResetsAt.timeIntervalSince(week.resetsAt) / duration,
                lower: 0,
                upper: Double.greatestFiniteMagnitude)
            let weight = exp(-ageWeeks / Self.recencyTauWeeks)
            return (week: week, weight: weight)
        }
        let totalWeight = weightedWeeks.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > Self.epsilon else { return nil }

        let totalWeightSquared = weightedWeeks.reduce(0.0) { $0 + ($1.weight * $1.weight) }
        let nEff = totalWeightSquared > Self.epsilon ? (totalWeight * totalWeight) / totalWeightSquared : 0
        let lambda = Self.clamp((nEff - 2) / 6, lower: 0, upper: 1)

        let gridCount = CodexHistoricalDataset.gridPointCount
        let denominator = Double(gridCount - 1)
        var expectedCurve = Array(repeating: 0.0, count: gridCount)
        for index in 0..<gridCount {
            let u = Double(index) / denominator
            let values = weightedWeeks.map { $0.week.curve[index] }
            let weights = weightedWeeks.map(\.weight)
            let historicalMedian = Self.weightedMedian(values: values, weights: weights)
            let linearBaseline = 100 * u
            expectedCurve[index] = Self.clamp(
                (lambda * historicalMedian) + ((1 - lambda) * linearBaseline),
                lower: 0,
                upper: 100)
        }

        // Expected cumulative usage should be monotone.
        var runningExpected = 0.0
        for index in expectedCurve.indices {
            runningExpected = max(runningExpected, expectedCurve[index])
            expectedCurve[index] = runningExpected
        }

        let expectedNow = Self.interpolate(curve: expectedCurve, at: uNow)

        var weightedRunOutMass = 0.0
        var crossingCandidates: [(etaSeconds: TimeInterval, weight: Double)] = []
        crossingCandidates.reserveCapacity(weightedWeeks.count)

        for weighted in weightedWeeks {
            let week = weighted.week
            let weight = weighted.weight
            let weekNow = Self.interpolate(curve: week.curve, at: uNow)
            let shift = actual - weekNow
            let shiftedEnd = Self.clamp((week.curve.last ?? 0) + shift, lower: 0, upper: 100)
            let runOut = shiftedEnd >= 100 - Self.epsilon
            if runOut {
                weightedRunOutMass += weight
                if let crossingU = Self.firstCrossing(
                    after: uNow,
                    curve: week.curve,
                    shift: shift,
                    actualAtNow: actual)
                {
                    let etaSeconds = max(0, (crossingU - uNow) * duration)
                    crossingCandidates.append((etaSeconds: etaSeconds, weight: weight))
                }
            }
        }

        let smoothedProbability = Self.clamp(
            (weightedRunOutMass + 0.5) / (totalWeight + 1),
            lower: 0,
            upper: 1)
        let runOutProbability: Double? = scopedWeeks.count >= Self.minimumWeeksForRisk ? smoothedProbability : nil

        var willLastToReset = smoothedProbability < 0.5
        var etaSeconds: TimeInterval?

        if !willLastToReset {
            let values = crossingCandidates.map(\.etaSeconds)
            let weights = crossingCandidates.map(\.weight)
            if values.isEmpty {
                willLastToReset = true
            } else {
                etaSeconds = max(0, Self.weightedMedian(values: values, weights: weights))
            }
        }

        return UsagePace.historical(
            expectedUsedPercent: expectedNow,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            runOutProbability: runOutProbability)
    }

    private static func firstCrossing(
        after uNow: Double,
        curve: [Double],
        shift: Double,
        actualAtNow: Double) -> Double?
    {
        let gridCount = curve.count
        guard gridCount >= 2 else { return nil }

        let denominator = Double(gridCount - 1)
        var previousU = uNow
        var previousValue = actualAtNow

        let startIndex = min(gridCount - 1, max(1, Int(floor(uNow * denominator)) + 1))
        for index in startIndex..<gridCount {
            let u = Double(index) / denominator
            if u <= uNow + Self.epsilon { continue }
            let value = Self.clamp(curve[index] + shift, lower: 0, upper: 100)
            if previousValue < 100 - Self.epsilon, value >= 100 - Self.epsilon {
                let delta = value - previousValue
                if abs(delta) <= Self.epsilon { return u }
                let ratio = Self.clamp((100 - previousValue) / delta, lower: 0, upper: 1)
                return Self.clamp(previousU + ratio * (u - previousU), lower: uNow, upper: 1)
            }
            previousU = u
            previousValue = value
        }
        return nil
    }

    private static func interpolate(curve: [Double], at u: Double) -> Double {
        guard !curve.isEmpty else { return 0 }
        if curve.count == 1 { return curve[0] }

        let clipped = Self.clamp(u, lower: 0, upper: 1)
        let scaled = clipped * Double(curve.count - 1)
        let lower = Int(floor(scaled))
        let upper = min(curve.count - 1, lower + 1)
        if lower == upper { return curve[lower] }
        let ratio = scaled - Double(lower)
        return curve[lower] + ((curve[upper] - curve[lower]) * ratio)
    }

    private static func weightedMedian(values: [Double], weights: [Double]) -> Double {
        guard values.count == weights.count, !values.isEmpty else { return 0 }
        let pairs = zip(values, weights)
            .map { (value: $0, weight: max(0, $1)) }
            .sorted { lhs, rhs in lhs.value < rhs.value }
        let totalWeight = pairs.reduce(0.0) { $0 + $1.weight }
        if totalWeight <= Self.epsilon {
            let sortedValues = values.sorted()
            return sortedValues[sortedValues.count / 2]
        }

        let threshold = totalWeight / 2
        var cumulative = 0.0
        for pair in pairs {
            cumulative += pair.weight
            if cumulative >= threshold {
                return pair.value
            }
        }
        return pairs.last?.value ?? 0
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }

    private static func normalizeReset(_ value: Date) -> Date {
        let bucket = Self.resetBucketSeconds
        guard bucket > 0 else { return value }
        let rounded = (value.timeIntervalSinceReferenceDate / bucket).rounded() * bucket
        return Date(timeIntervalSinceReferenceDate: rounded)
    }
}
