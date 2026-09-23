import CoreFoundation
import Foundation

/// One local-calendar day of Grok session-token activity.
/// `requestCount` counts completed turns; a signal-only day counts one per session.
public struct GrokLocalDailyBucket: Sendable, Equatable {
    public let date: String
    public let totalTokens: Int
    public let sessionCount: Int
    public let models: [String]
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?
    public let requestCount: Int

    public init(
        date: String,
        totalTokens: Int,
        sessionCount: Int,
        models: [String],
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        requestCount: Int = 0)
    {
        self.date = date
        self.totalTokens = totalTokens
        self.sessionCount = sessionCount
        self.models = models
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.requestCount = requestCount
    }
}

/// Aggregated stats from local `~/.grok/sessions/**/signals.json` files.
/// Used as a local fallback view when the JSON-RPC billing call is unavailable.
public struct GrokLocalSessionSummary: Sendable {
    public let sessionCount: Int
    public let totalTokens: Int
    public let lastSessionAt: Date?
    public let primaryModel: String?
    public let models: [String]
    public let daily: [GrokLocalDailyBucket]
    public let scannedAt: Date
    public let historyCoverageIsEstablished: Bool

    public init(
        sessionCount: Int,
        totalTokens: Int,
        lastSessionAt: Date?,
        primaryModel: String?,
        models: [String],
        daily: [GrokLocalDailyBucket] = [],
        scannedAt: Date = .init(),
        historyCoverageIsEstablished: Bool = true)
    {
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.lastSessionAt = lastSessionAt
        self.primaryModel = primaryModel
        self.models = models
        self.daily = daily
        self.scannedAt = scannedAt
        self.historyCoverageIsEstablished = historyCoverageIsEstablished
    }

    /// Token counts come from completed turns, falling back to signal-only context
    /// size. SuperGrok credits remain a quota and are never converted into dollars.
    public func toCostUsageTokenSnapshot(historyDays: Int) -> CostUsageTokenSnapshot? {
        let entries = self.daily.map { bucket in
            CostUsageDailyReport.Entry(
                date: bucket.date,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheReadTokens: bucket.cacheReadTokens,
                cacheCreationTokens: bucket.cacheCreationTokens,
                totalTokens: bucket.totalTokens,
                requestCount: bucket.requestCount,
                costUSD: nil,
                modelsUsed: bucket.models.isEmpty ? nil : bucket.models,
                modelBreakdowns: nil)
        }
        guard !entries.isEmpty else { return nil }
        let todayKey = GrokLocalSessionScanner.dayKey(for: self.scannedAt, calendar: .current)
        let today = todayKey.flatMap { key in entries.first { $0.date == key } }
        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: nil,
            last30DaysTokens: self.totalTokens,
            last30DaysCostUSD: nil,
            historyDays: historyDays,
            historyCoverageIsEstablished: self.historyCoverageIsEstablished,
            daily: entries,
            updatedAt: self.scannedAt)
    }
}

public enum GrokLocalSessionScanner {
    public static let defaultLookbackDays = 30

    /// Walk `~/.grok/sessions/<encoded_cwd>/<session_id>/` and aggregate stats.
    /// `updates.jsonl` turn usage replaces the context-size signal for that session.
    public static func summarize(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) -> GrokLocalSessionSummary
    {
        let root = GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let rootEnum = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        else {
            return self.emptySummary(now: now)
        }

        let calendar = Calendar.current
        // Calendar-day window: the report covers whole local days, matching the narrowed
        // projection and the CLI's day labels. A one-day report is today only.
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(max(lookbackDays, 1) - 1), to: startOfToday)
            ?? startOfToday
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? .distantFuture
        let window = windowStart..<windowEnd
        var sessions: [String: SessionScan] = [:]

        while let url = rootEnum.nextObject() as? URL {
            let name = url.lastPathComponent
            guard name == "signals.json" || name == "updates.jsonl" else { continue }
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = attrs?.contentModificationDate ?? Date.distantPast
            guard window.contains(mtime) else { continue }
            let key = url.deletingLastPathComponent().path
            var session = sessions[key] ?? SessionScan()
            if name == "signals.json" {
                self.readSignals(url: url, mtime: mtime, calendar: calendar, into: &session)
            } else if (attrs?.fileSize ?? 0) <= self.maxTurnLogBytes {
                self.readTurns(url: url, mtime: mtime, into: &session)
            } else {
                session.turnLogOversized = true
            }
            sessions[key] = session
        }

        var sessionCount = 0
        var totalTokens = 0
        var lastSessionAt: Date?
        var modelCounts: [String: Int] = [:]
        var days: [String: DayAccum] = [:]

        for session in sessions.values {
            let contribution = self.contribution(session, window: window)
            guard !contribution.pieces.isEmpty else { continue }
            sessionCount += 1
            if let at = contribution.lastAt, at > (lastSessionAt ?? Date.distantPast) {
                lastSessionAt = at
            }
            var countedDays = Set<String>()
            for piece in contribution.pieces {
                guard let added = self.checkedAdd(totalTokens, piece.totalTokens) else { continue }
                totalTokens = added
                for model in piece.models {
                    modelCounts[model, default: 0] += 1
                }
                var day = days[piece.day] ?? DayAccum()
                if countedDays.insert(piece.day).inserted {
                    day.sessions += 1
                }
                day.add(piece)
                days[piece.day] = day
            }
        }

        let sortedModels = modelCounts.sorted { $0.value > $1.value }.map(\.key)
        let daily = days.keys.sorted().map { key in
            let day = days[key] ?? DayAccum()
            return day.bucket(date: key)
        }
        // A skipped oversized log or a discarded malformed turn set leaves turn
        // data out of the scan, even when the signal still covers the session totals.
        let complete = !sessions.values.contains { $0.turnLogOversized || $0.turnParseFailed }
        return GrokLocalSessionSummary(
            sessionCount: sessionCount,
            totalTokens: totalTokens,
            lastSessionAt: lastSessionAt,
            primaryModel: sortedModels.first,
            models: sortedModels,
            daily: daily,
            scannedAt: now,
            historyCoverageIsEstablished: complete)
    }

    public static func summarizeOffMainThread(
        env: [String: String],
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) async throws -> GrokLocalSessionSummary
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try checkCancellation()
            let summary = Self.summarize(
                env: env,
                fileManager: .default,
                lookbackDays: lookbackDays,
                now: now)
            try checkCancellation()
            return summary
        }
    }

    private static let maxTurnLogBytes = 32 * 1024 * 1024

    private struct SessionScan {
        var signalTokens: Int?
        var signalDay: String?
        var signalAt: Date?
        var signalModels: [String] = []
        var turns: [Turn] = []
        var turnParseFailed = false
        var turnLogOversized = false
    }

    private struct Turn {
        let at: Date
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let total: Int
    }

    private struct Piece {
        let day: String
        let models: [String]
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
        let totalTokens: Int
        let requests: Int
    }

    private struct Contribution {
        var pieces: [Piece] = []
        var lastAt: Date?
    }

    private struct DayAccum {
        var tokens = 0
        var sessions = 0
        var requests = 0
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheWrite: Int?
        var models = Set<String>()

        mutating func add(_ piece: Piece) {
            self.tokens += piece.totalTokens
            self.requests += piece.requests
            if let input = piece.input, let output = piece.output {
                self.input = (self.input ?? 0) + input
                self.output = (self.output ?? 0) + output
                self.cacheRead = (self.cacheRead ?? 0) + (piece.cacheRead ?? 0)
                self.cacheWrite = (self.cacheWrite ?? 0) + (piece.cacheWrite ?? 0)
            }
            for model in piece.models {
                self.models.insert(model)
            }
        }

        func bucket(date: String) -> GrokLocalDailyBucket {
            GrokLocalDailyBucket(
                date: date,
                totalTokens: self.tokens,
                sessionCount: self.sessions,
                models: self.models.sorted(),
                inputTokens: self.input,
                outputTokens: self.output,
                cacheReadTokens: self.cacheRead,
                cacheCreationTokens: self.cacheWrite,
                requestCount: self.requests)
        }
    }

    private static func emptySummary(now: Date) -> GrokLocalSessionSummary {
        GrokLocalSessionSummary(
            sessionCount: 0,
            totalTokens: 0,
            lastSessionAt: nil,
            primaryModel: nil,
            models: [],
            scannedAt: now)
    }

    private static func readSignals(
        url: URL,
        mtime: Date,
        calendar: Calendar,
        into session: inout SessionScan)
    {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let beforeCompaction = self.intValue(json["totalTokensBeforeCompaction"]) ?? 0
        let contextUsed = self.intValue(json["contextTokensUsed"]) ?? 0
        guard let tokens = self.checkedAdd(beforeCompaction, contextUsed), tokens >= 0 else { return }
        session.signalTokens = tokens
        session.signalDay = self.dayKey(for: mtime, calendar: calendar)
        session.signalAt = mtime
        var models: [String] = []
        if let primary = (json["primaryModelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !primary.isEmpty
        {
            models.append(primary)
        }
        if let used = json["modelsUsed"] as? [String] {
            for model in used {
                let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !models.contains(trimmed) {
                    models.append(trimmed)
                }
            }
        }
        session.signalModels = models
    }

    private static func readTurns(url: URL, mtime: Date, into session: inout SessionScan) {
        guard let data = try? Data(contentsOf: url) else { return }
        // A log that is not UTF-8 falls back to the context signal instead of counting repaired text.
        guard let text = String(bytes: data, encoding: .utf8) else {
            session.turnParseFailed = true
            return
        }
        var seen: [String: [String: Turn]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard raw.contains("\"sessionUpdate\":\"turn_completed\"")
                || raw.contains("\"sessionUpdate\": \"turn_completed\"")
            else { continue }
            guard let identified = self.turns(from: raw, fallbackDate: mtime) else {
                session.turnParseFailed = true
                continue
            }
            guard let prompt = identified.promptID else {
                session.turns.append(contentsOf: identified.turns)
                continue
            }
            // A replayed prompt replaces every model recorded by its earlier line.
            seen[prompt] = Dictionary(
                identified.turns.map { ($0.model, $0) },
                uniquingKeysWith: { _, latest in latest })
        }
        if session.turnParseFailed {
            session.turns = []
            return
        }
        session.turns.append(contentsOf: seen.values.flatMap(\.values))
    }

    private struct IdentifiedTurns {
        let promptID: String?
        let turns: [Turn]
    }

    private static func turns(from line: String, fallbackDate: Date) -> IdentifiedTurns? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = json["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any]
        else { return nil }
        let at = self.intValue(json["timestamp"]).map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? fallbackDate
        let prompt = update["prompt_id"] as? String
        if let models = usage["modelUsage"] as? [String: Any], !models.isEmpty {
            // A turn that fanned out to several models counts each model's usage.
            // One malformed entry fails the line.
            var turns: [Turn] = []
            for name in models.keys.sorted() {
                guard let body = models[name] as? [String: Any],
                      let turn = self.turn(model: name, usage: body, at: at)
                else { return nil }
                turns.append(turn)
            }
            return IdentifiedTurns(promptID: prompt, turns: turns)
        }
        guard let turn = self.turn(model: "unknown", usage: usage, at: at) else { return nil }
        return IdentifiedTurns(promptID: prompt, turns: [turn])
    }

    private static func turn(model: String, usage: [String: Any], at: Date) -> Turn? {
        guard let input = self.intValue(usage["inputTokens"]),
              let output = self.intValue(usage["outputTokens"]),
              input >= 0, output >= 0,
              let total = self.checkedAdd(input, output)
        else { return nil }
        let cacheRead = self.intValue(usage["cachedReadTokens"]) ?? 0
        let cacheWrite = self.intValue(usage["cacheCreationTokens"]) ?? 0
        guard cacheRead >= 0, cacheWrite >= 0, cacheRead <= input, cacheWrite <= input else { return nil }
        if let recorded = self.intValue(usage["totalTokens"]), recorded != total { return nil }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return Turn(
            at: at,
            model: name.isEmpty ? "unknown" : name,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            total: total)
    }

    private static func contribution(_ session: SessionScan, window: Range<Date>) -> Contribution {
        let calendar = Calendar.current
        if !session.turns.isEmpty, !session.turnParseFailed {
            var pieces: [Piece] = []
            var last: Date?
            for turn in session.turns where window.contains(turn.at) {
                guard let day = self.dayKey(for: turn.at, calendar: calendar) else { continue }
                pieces.append(Piece(
                    day: day,
                    models: [turn.model],
                    input: turn.input,
                    output: turn.output,
                    cacheRead: turn.cacheRead,
                    cacheWrite: turn.cacheWrite,
                    totalTokens: turn.total,
                    requests: 1))
                if let previous = last {
                    if turn.at > previous { last = turn.at }
                } else {
                    last = turn.at
                }
            }
            return Contribution(pieces: pieces, lastAt: last)
        }
        guard let tokens = session.signalTokens, let day = session.signalDay, tokens > 0 || session.signalAt != nil
        else { return Contribution() }
        return Contribution(
            pieces: [Piece(
                day: day,
                models: session.signalModels.isEmpty ? ["unknown"] : session.signalModels,
                input: nil,
                output: nil,
                cacheRead: nil,
                cacheWrite: nil,
                totalTokens: tokens,
                requests: 1)],
            lastAt: session.signalAt)
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
