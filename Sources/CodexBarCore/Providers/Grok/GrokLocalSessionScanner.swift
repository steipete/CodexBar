import Foundation

/// One local-calendar day of Grok session-token activity.
public struct GrokLocalDailyBucket: Sendable, Equatable {
    public let date: String
    public let totalTokens: Int
    public let sessionCount: Int
    public let models: [String]

    public init(date: String, totalTokens: Int, sessionCount: Int, models: [String]) {
        self.date = date
        self.totalTokens = totalTokens
        self.sessionCount = sessionCount
        self.models = models
    }
}

/// Aggregated stats from local `~/.grok/sessions/<encoded_cwd>/<session_id>/` usage files.
/// Used as a local fallback view when the JSON-RPC billing call is unavailable.
public struct GrokLocalSessionSummary: Sendable {
    public let sessionCount: Int
    public let totalTokens: Int
    public let lastSessionAt: Date?
    public let primaryModel: String?
    public let models: [String]
    public let daily: [GrokLocalDailyBucket]
    public let scannedAt: Date

    public init(
        sessionCount: Int,
        totalTokens: Int,
        lastSessionAt: Date?,
        primaryModel: String?,
        models: [String],
        daily: [GrokLocalDailyBucket] = [],
        scannedAt: Date = .init())
    {
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.lastSessionAt = lastSessionAt
        self.primaryModel = primaryModel
        self.models = models
        self.daily = daily
        self.scannedAt = scannedAt
    }

    /// Local session tokens only. SuperGrok credits are a quota, not dollars, so this never invents spend.
    public func toCostUsageTokenSnapshot(historyDays: Int) -> CostUsageTokenSnapshot? {
        let entries = self.daily.map { bucket in
            CostUsageDailyReport.Entry(
                date: bucket.date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: bucket.totalTokens,
                requestCount: bucket.sessionCount,
                costUSD: nil,
                modelsUsed: bucket.models.isEmpty ? nil : bucket.models,
                modelBreakdowns: nil)
        }
        guard !entries.isEmpty else { return nil }
        let todayKey = GrokLocalSessionScanner.dayKey(for: self.scannedAt, calendar: .current)
        let todayTokens = todayKey.flatMap { key in self.daily.first { $0.date == key }?.totalTokens }
        return CostUsageTokenSnapshot(
            sessionTokens: todayTokens,
            sessionCostUSD: nil,
            last30DaysTokens: self.totalTokens,
            last30DaysCostUSD: nil,
            historyDays: historyDays,
            historyCoverageIsEstablished: true,
            costProvenance: .unknown,
            daily: entries,
            updatedAt: self.scannedAt)
    }
}

public enum GrokLocalSessionScanner {
    public static let defaultLookbackDays = 30

    /// Walk `~/.grok/sessions/<encoded_cwd>/<session_id>/` and aggregate stats. `usage.json` records every turn, so
    /// it is preferred; `signals.json` only keeps a session-level figure and drops most tokens after compaction.
    public static func summarize(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) -> GrokLocalSessionSummary
    {
        let root = GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
        let rootEnum = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let lookbackCutoff = calendar.date(byAdding: .day, value: -(max(1, lookbackDays) - 1), to: today) ?? today
        let lookbackEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        var sessionCount = 0
        var totalTokens = 0
        var lastSessionAt: Date?
        var modelCounts: [String: Int] = [:]
        var dailyTokens: [String: Int] = [:]
        var dailySessions: [String: Int] = [:]
        var dailyModels: [String: [String: Int]] = [:]

        while let rootEnum, let sessionURL = rootEnum.nextObject() as? URL {
            guard rootEnum.level == 2 else { continue }
            // Session artifacts can be large; only the session's own usage files describe its usage.
            rootEnum.skipDescendants()
            guard (try? sessionURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let turns = Self.usageTurns(in: sessionURL, notBefore: lookbackCutoff) {
                let turnsInWindow = turns.filter { $0.endedAt >= lookbackCutoff && $0.endedAt < lookbackEnd }
                guard !turnsInWindow.isEmpty else { continue }
                sessionCount += 1
                var sessionDays = Set<String>()
                for turn in turnsInWindow {
                    totalTokens += turn.totalTokens
                    if turn.endedAt > (lastSessionAt ?? Date.distantPast) {
                        lastSessionAt = turn.endedAt
                    }
                    for model in turn.models {
                        modelCounts[model, default: 0] += 1
                    }
                    guard let day = Self.dayKey(for: turn.endedAt, calendar: calendar) else { continue }
                    dailyTokens[day, default: 0] += turn.totalTokens
                    sessionDays.insert(day)
                    for model in turn.models {
                        dailyModels[day, default: [:]][model, default: 0] += 1
                    }
                }
                for day in sessionDays {
                    dailySessions[day, default: 0] += 1
                }
                continue
            }

            let url = sessionURL.appendingPathComponent("signals.json")
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = attrs?.contentModificationDate ?? Date.distantPast
            guard mtime >= lookbackCutoff, mtime < lookbackEnd,
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            sessionCount += 1
            let beforeCompaction = (json["totalTokensBeforeCompaction"] as? Int) ?? 0
            let contextUsed = (json["contextTokensUsed"] as? Int) ?? 0
            let sessionTokens = beforeCompaction + contextUsed
            totalTokens += sessionTokens

            if mtime > (lastSessionAt ?? Date.distantPast) {
                lastSessionAt = mtime
            }

            var sessionModels: [String] = []
            if let primary = (json["primaryModelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !primary.isEmpty
            {
                modelCounts[primary, default: 0] += 1
                sessionModels.append(primary)
            }
            if let models = json["modelsUsed"] as? [String] {
                for model in models {
                    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        modelCounts[trimmed, default: 0] += 1
                        sessionModels.append(trimmed)
                    }
                }
            }

            if let day = Self.dayKey(for: mtime, calendar: calendar) {
                dailyTokens[day, default: 0] += sessionTokens
                dailySessions[day, default: 0] += 1
                for model in sessionModels {
                    dailyModels[day, default: [:]][model, default: 0] += 1
                }
            }
        }

        let sortedModels = modelCounts.sorted { $0.value > $1.value }.map(\.key)
        let daily = dailyTokens.keys.sorted().map { day in
            let models = (dailyModels[day] ?? [:]).sorted { $0.value > $1.value }.map(\.key)
            return GrokLocalDailyBucket(
                date: day,
                totalTokens: dailyTokens[day] ?? 0,
                sessionCount: dailySessions[day] ?? 0,
                models: models)
        }
        return GrokLocalSessionSummary(
            sessionCount: sessionCount,
            totalTokens: totalTokens,
            lastSessionAt: lastSessionAt,
            primaryModel: sortedModels.first,
            models: sortedModels,
            daily: daily,
            scannedAt: now)
    }

    private struct UsageTurn {
        let endedAt: Date
        let totalTokens: Int
        let models: [String]
    }

    /// Returns nil when `usage.json` is missing, too old for the window, or holds no readable turn.
    private static func usageTurns(in session: URL, notBefore cutoff: Date) -> [UsageTurn]? {
        let url = session.appendingPathComponent("usage.json")
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified, modified >= cutoff,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["turns"] as? [[String: Any]]
        else { return nil }
        let turns = records.compactMap { record -> UsageTurn? in
            guard let timestamp = record["endedAt"] as? String,
                  let endedAt = CostUsageScanner.dateFromTimestamp(timestamp),
                  let totalTokens = record["totalTokens"] as? Int, totalTokens >= 0
            else { return nil }
            let usageModels = (record["modelUsage"] as? [String: Any]).map { Array($0.keys) } ?? []
            let primary = (record["primaryModelId"] as? String).map { [$0] } ?? []
            let models = (usageModels.isEmpty ? primary : usageModels)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return UsageTurn(endedAt: endedAt, totalTokens: totalTokens, models: models)
        }
        return turns.isEmpty ? nil : turns
    }

    public static func summarizeOffMainThread(
        env: [String: String],
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) async throws -> GrokLocalSessionSummary
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try checkCancellation()
            let summary = Self.summarize(env: env, lookbackDays: lookbackDays, now: now)
            try checkCancellation()
            return summary
        }
    }

    package static func dayKey(for date: Date, calendar: Calendar) -> String? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        return CostUsageLocalDay.key(year: year, month: month, day: day)
    }
}
