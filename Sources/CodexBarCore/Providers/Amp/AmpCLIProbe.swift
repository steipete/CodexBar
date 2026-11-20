import Foundation

public struct AmpCLIProbe: Sendable {
    private static let commandTimeout: TimeInterval = 15
    private static let historyDays = 30
    private static let maxConcurrentDayQueries = 8
    /// Amp can record cost shortly after a day ends; only days that ended this long ago are reused.
    private static let settledDayAge: TimeInterval = 6 * 60 * 60
    private let arguments: [String]
    private let calendar: Calendar

    /// - Parameter calendar: The Statistics calendar; Amp history is queried and keyed by its days.
    public init(calendar: Calendar = .current) {
        self.arguments = ["usage"]
        self.calendar = calendar
    }

    init(arguments: [String], calendar: Calendar = .current) {
        self.arguments = arguments
        self.calendar = calendar
    }

    public func fetch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> AmpUsageSnapshot
    {
        let loginPATH = LoginShellPathCache.shared.current
        guard let executable = BinaryLocator.resolveAmpBinary(env: environment, loginPATH: loginPATH) else {
            throw SubprocessRunnerError.binaryNotFound("amp")
        }

        var commandEnvironment = environment
        commandEnvironment["NO_COLOR"] = "1"
        commandEnvironment["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: environment,
            loginPATH: loginPATH)

        let command = Command(executable: executable, arguments: self.arguments, environment: commandEnvironment)
        let output = try await command.run()
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AmpUsageError.parseFailed("The Amp CLI returned no usage data.")
        }
        var snapshot = try AmpUsageParser.parse(displayText: output, now: now)
        // Enterprise-paid workspaces expose no balance, so recorded totals are the only usage Amp reports.
        // Best-effort: a failed detail run must not hide the account that was already parsed.
        if !snapshot.enterpriseWorkspaces.isEmpty, snapshot.recentUsage == nil {
            snapshot.recentUsage = try await self.recentUsage(
                command: command,
                account: snapshot.accountEmail,
                now: now)
        }
        return snapshot
    }

    private func recentUsage(command: Command, account: String?, now: Date) async throws -> AmpRecentUsage? {
        let calendar = CostUsageLocalDay.gregorianCalendar(matching: self.calendar)
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(Self.historyDays - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today)
        else { return nil }

        let details: String
        do {
            details = try await command.run(Self.detailArguments(start: start, end: end))
        } catch {
            try Task.checkCancellation()
            return nil
        }
        guard var recent = AmpUsageParser.parseRecentUsage(displayText: details) else { return nil }

        // Amp reports tokens and models only for the whole range, so each active day is read on its own.
        let days = Self.activeLocalDays(recent.daily, calendar: calendar, start: start, end: end)
        let scope = ([command.executable] + command.arguments + [account ?? ""]).joined(separator: "\u{1F}")
        var usage: [AmpDailyUsage] = []
        var pending: [Date] = []
        for day in days {
            if let cached = await AmpDailyUsageCache.shared.value(scope: scope, day: day) {
                usage.append(cached)
            } else {
                pending.append(day)
            }
        }

        let fetched = await withTaskGroup(of: (Date, AmpDailyUsage?).self) { group in
            var iterator = pending.makeIterator()
            var results: [(Date, AmpDailyUsage?)] = []
            let addNext: (inout TaskGroup<(Date, AmpDailyUsage?)>) -> Void = { group in
                guard let day = iterator.next() else { return }
                group.addTask { await (day, Self.dayUsage(command: command, day: day, calendar: calendar)) }
            }
            for _ in 0..<Self.maxConcurrentDayQueries {
                addNext(&group)
            }
            for await result in group {
                results.append(result)
                addNext(&group)
            }
            return results
        }
        try Task.checkCancellation()

        for (day, value) in fetched {
            guard let value else {
                recent.unreadDays.insert(CostUsageLocalDay.key(from: day, calendar: calendar))
                continue
            }
            usage.append(value)
            if let dayEnd = calendar.date(byAdding: .day, value: 1, to: day),
               now.timeIntervalSince(dayEnd) >= Self.settledDayAge
            {
                await AmpDailyUsageCache.shared.store(value, scope: scope, day: day)
            }
        }
        recent.dailyUsage = usage
            .filter { ($0.tokens ?? 0) > 0 || ($0.cost ?? 0) > 0 }
            .sorted { $0.date < $1.date }
        return recent
    }

    private static func dayUsage(command: Command, day: Date, calendar: Calendar) async -> AmpDailyUsage? {
        guard let end = calendar.date(byAdding: .day, value: 1, to: day),
              let output = try? await command.run(Self.detailArguments(start: day, end: end)),
              let parsed = AmpUsageParser.parseRecentUsage(displayText: output)
        else { return nil }
        return AmpDailyUsage(
            date: CostUsageLocalDay.key(from: day, calendar: calendar),
            cost: parsed.recordedCost,
            tokens: parsed.tokens,
            models: parsed.models)
    }

    /// Amp requires both bounds; without them it reports only the trailing 7 days.
    static func detailArguments(start: Date, end: Date) -> [String] {
        let formatter = ISO8601DateFormatter()
        return ["--details", "--start", formatter.string(from: start), "--end", formatter.string(from: end)]
    }

    /// Local days overlapping the UTC days Amp reported cost for, so idle days cost no extra CLI runs.
    static func activeLocalDays(
        _ daily: [AmpDailyRecordedCost],
        calendar: Calendar,
        start: Date,
        end: Date) -> [Date]
    {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        var days: Set<Date> = []
        for entry in daily {
            guard let utcStart = formatter.date(from: entry.date) else { continue }
            days.insert(calendar.startOfDay(for: utcStart))
            days.insert(calendar.startOfDay(for: utcStart.addingTimeInterval(24 * 60 * 60 - 1)))
        }
        return days.filter { $0 >= start && $0 < end }.sorted()
    }

    private struct Command: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]

        func run(_ extraArguments: [String] = []) async throws -> String {
            let result = try await SubprocessRunner.run(
                binary: self.executable,
                arguments: self.arguments + extraArguments,
                environment: self.environment,
                timeout: AmpCLIProbe.commandTimeout,
                standardInput: FileHandle.nullDevice,
                label: "amp-usage")
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stderr
                : result.stdout
        }
    }
}

/// Settled days never change, so they are read from Amp once per launch instead of on every refresh.
private actor AmpDailyUsageCache {
    static let shared = AmpDailyUsageCache()
    private static let maximumEntries = 512
    private var values: [String: AmpDailyUsage] = [:]

    func value(scope: String, day: Date) -> AmpDailyUsage? {
        self.values[Self.key(scope: scope, day: day)]
    }

    func store(_ value: AmpDailyUsage, scope: String, day: Date) {
        if self.values.count >= Self.maximumEntries {
            self.values.removeAll()
        }
        self.values[Self.key(scope: scope, day: day)] = value
    }

    private static func key(scope: String, day: Date) -> String {
        "\(scope)\u{1F}\(day.timeIntervalSince1970)"
    }
}
