import Foundation

enum OpenClawCostUsageFetcher {
    private struct GatewaySummary: Decodable {
        let daily: [GatewayDay]
        let cacheStatus: CacheStatus?
    }

    private struct GatewayDay: Decodable {
        let date: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let totalTokens: Int
        let totalCost: Double
        let missingCostEntries: Int
    }

    private struct CacheStatus: Decodable {
        let status: String
    }

    static func arguments(now: Date, historyDays: Int, calendar: Calendar) throws -> [String] {
        let days = max(1, min(365, historyDays))
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let data = try JSONSerialization.data(withJSONObject: [
            "agentScope": "all",
            "endDate": CostUsageLocalDay.key(from: today, calendar: calendar),
            "mode": "specific",
            "startDate": CostUsageLocalDay.key(from: firstDay, calendar: calendar),
            "timeZone": calendar.timeZone.identifier,
        ], options: [.sortedKeys])
        guard let parameters = String(bytes: data, encoding: .utf8) else {
            throw OpenClawUsageError.invalidResponse
        }
        return [
            "gateway", "call", "usage.cost",
            "--params", parameters,
            "--timeout", "20000", "--json",
        ]
    }

    static func fetchDailyReport(
        environment: [String: String],
        now: Date,
        historyDays: Int,
        calendar: Calendar) async throws -> CostUsageDailyReport
    {
        let loginPATH = LoginShellPathCache.shared.current
        guard let binary = BinaryLocator.resolveOpenClawBinary(env: environment, loginPATH: loginPATH) else {
            throw SubprocessRunnerError.binaryNotFound("openclaw")
        }
        var commandEnvironment = environment
        commandEnvironment["NO_COLOR"] = "1"
        commandEnvironment["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling], env: environment, loginPATH: loginPATH)
        let result = try await SubprocessRunner.run(
            binary: binary,
            arguments: self.arguments(now: now, historyDays: historyDays, calendar: calendar),
            environment: commandEnvironment,
            timeout: 25,
            maxOutputBytes: 4 * 1024 * 1024,
            standardInput: FileHandle.nullDevice,
            label: "openclaw-usage-cost")
        return try self.parseDailyReport(result.stdout)
    }

    static func parseDailyReport(_ output: String) throws -> CostUsageDailyReport {
        let data = Data(output.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty else { throw OpenClawUsageError.invalidResponse }
        guard let summary = try? JSONDecoder().decode(GatewaySummary.self, from: data) else {
            throw OpenClawUsageError.invalidResponse
        }
        if let status = summary.cacheStatus?.status, status != "fresh" {
            throw OpenClawUsageError.incompleteCache(status)
        }

        var seenDates = Set<String>()
        var knownCostTotal = 0.0
        let entries = try summary.daily.map { day in
            let counts = [day.input, day.output, day.cacheRead, day.cacheWrite, day.totalTokens, day.missingCostEntries]
            guard Self.isValidDayKey(day.date), seenDates.insert(day.date).inserted,
                  counts.allSatisfy({ $0 >= 0 }), day.totalCost.isFinite, day.totalCost >= 0
            else { throw OpenClawUsageError.invalidResponse }
            if day.missingCostEntries == 0 {
                knownCostTotal += day.totalCost
                guard knownCostTotal.isFinite else { throw OpenClawUsageError.invalidResponse }
            }
            return CostUsageDailyReport.Entry(
                date: day.date,
                inputTokens: day.input,
                outputTokens: day.output,
                cacheReadTokens: day.cacheRead,
                cacheCreationTokens: day.cacheWrite,
                totalTokens: day.totalTokens,
                costUSD: day.missingCostEntries == 0 ? day.totalCost : nil,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        return CostUsageDailyReport(data: entries.sorted { $0.date < $1.date }, summary: nil)
    }

    private static func isValidDayKey(_ value: String) -> Bool {
        guard value.count == 10, let date = CostUsageDateParser.parse(value) else { return false }
        return CostUsageLocalDay.key(from: date) == value
    }
}

enum OpenClawUsageError: LocalizedError, Equatable {
    case incompleteCache(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .incompleteCache(status):
            "OpenClaw usage cache is \(status); retry after the Gateway refresh finishes."
        case .invalidResponse:
            "The OpenClaw Gateway returned invalid usage JSON."
        }
    }
}
