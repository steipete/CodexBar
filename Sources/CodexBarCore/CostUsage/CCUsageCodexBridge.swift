import Foundation

/// Optional bridge to ccusage for Codex archives whose native cache is still catching up.
///
/// The bridge is deliberately opt-in: CodexBar never searches PATH or downloads a helper.
/// Packagers may bundle `Contents/Helpers/ccusage`, while local users can point at a vetted
/// executable with `CODEXBAR_CCUSAGE_PATH`.
enum CCUsageCodexBridge {
    private static let log = CodexBarLog.logger(LogCategories.tokenCost)
    private static let defaultTimeout: TimeInterval = 30
    private static let defaultMaxOutputBytes = 16 * 1024 * 1024

    private struct Output: Decodable {
        let daily: [Day]
    }

    private struct Day: Decodable {
        let period: String
        let agents: [Agent]
    }

    private struct Agent: Decodable {
        let agent: String
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheCreationTokens: Int?
        let totalTokens: Int?
        let totalCost: Double?
        let modelsUsed: [String]?
        let modelBreakdowns: [ModelBreakdown]?
    }

    private struct ModelBreakdown: Decodable {
        let modelName: String
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheCreationTokens: Int?
        let totalTokens: Int?
        let cost: Double?
    }

    package static func executablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default) -> String?
    {
        var candidates: [String] = []
        if let override = environment["CODEXBAR_CCUSAGE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            candidates.append((override as NSString).expandingTildeInPath)
        }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Helpers/ccusage").path)
        if let executableURL = bundle.executableURL {
            candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent("ccusage").path)
        }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    package static func arguments(
        since: Date,
        until: Date,
        calendar: Calendar) -> [String]
    {
        [
            "daily",
            "--json",
            "--by-agent",
            "--offline",
            "--no-color",
            "--timezone", calendar.timeZone.identifier,
            "--since", self.dayKey(for: since, calendar: calendar),
            "--until", self.dayKey(for: until, calendar: calendar),
        ]
    }

    package static func subprocessEnvironment(
        environment: [String: String],
        codexHomePath: String?) -> [String: String]
    {
        var resolved = ProcessInfo.processInfo.environment
        resolved.merge(environment) { _, scoped in scoped }
        if let codexHome = CodexHomeScope.normalizedHomePath(codexHomePath) {
            resolved["CODEX_HOME"] = codexHome
        }
        return resolved
    }

    package static func loadFallbackReportIfNeeded(
        nativeReport: CostUsageDailyReport,
        historyCoverageIsEstablished: Bool,
        since: Date,
        until: Date,
        calendar: Calendar,
        environment: [String: String],
        codexHomePath: String?,
        timeout: TimeInterval = Self.defaultTimeout,
        maxOutputBytes: Int = Self.defaultMaxOutputBytes) async -> CostUsageDailyReport?
    {
        guard !historyCoverageIsEstablished else { return nil }
        guard self.executablePath(
            environment: self.subprocessEnvironment(environment: environment, codexHomePath: codexHomePath)) != nil
        else {
            return nil
        }

        do {
            let fallback = try await self.loadReport(
                since: since,
                until: until,
                calendar: calendar,
                environment: environment,
                codexHomePath: codexHomePath,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes)
            guard self.isAtLeastAsComplete(fallback, as: nativeReport) else {
                self.log.warning(
                    "Ignoring ccusage Codex fallback with fewer tokens than native scan",
                    metadata: ["reason": "lower-token-total"])
                return nil
            }
            return fallback
        } catch {
            self.log.warning(
                "ccusage Codex fallback failed; keeping native scan",
                metadata: ["reason": self.failureReason(for: error)])
            return nil
        }
    }

    package static func loadReport(
        since: Date,
        until: Date,
        calendar: Calendar,
        environment: [String: String],
        codexHomePath: String?,
        timeout: TimeInterval = Self.defaultTimeout,
        maxOutputBytes: Int = Self.defaultMaxOutputBytes) async throws -> CostUsageDailyReport
    {
        let processEnvironment = self.subprocessEnvironment(
            environment: environment,
            codexHomePath: codexHomePath)
        guard let executable = self.executablePath(environment: processEnvironment) else {
            throw SubprocessRunnerError.binaryNotFound("ccusage")
        }

        let result = try await SubprocessRunner.run(
            binary: executable,
            arguments: self.arguments(since: since, until: until, calendar: calendar),
            environment: processEnvironment,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            label: "ccusage-codex-daily")
        return try self.parseReport(Data(result.stdout.utf8))
    }

    package static func parseReport(_ data: Data) throws -> CostUsageDailyReport {
        let output = try JSONDecoder().decode(Output.self, from: data)
        let entries = output.daily.compactMap { day -> CostUsageDailyReport.Entry? in
            let codexAgents = day.agents.filter {
                $0.agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex"
            }
            guard !codexAgents.isEmpty else { return nil }

            let modelBreakdowns = self.mergeModelBreakdowns(codexAgents.flatMap { $0.modelBreakdowns ?? [] })
            let models = Set(codexAgents.flatMap { $0.modelsUsed ?? [] })
                .union(modelBreakdowns.map(\.modelName))
                .sorted()
            return CostUsageDailyReport.Entry(
                date: day.period,
                inputTokens: self.sum(codexAgents.map(\.inputTokens)),
                outputTokens: self.sum(codexAgents.map(\.outputTokens)),
                cacheReadTokens: self.sum(codexAgents.map(\.cacheReadTokens)),
                cacheCreationTokens: self.sum(codexAgents.map(\.cacheCreationTokens)),
                totalTokens: self.sum(codexAgents.map { $0.totalTokens ?? self.componentTotal(for: $0) }),
                costUSD: self.sum(codexAgents.map(\.totalCost)),
                modelsUsed: models.isEmpty ? nil : models,
                modelBreakdowns: modelBreakdowns.isEmpty ? nil : modelBreakdowns)
        }
        .sorted { $0.date < $1.date }

        return CostUsageDailyReport(
            data: entries,
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: self.sum(entries.map(\.inputTokens)),
                totalOutputTokens: self.sum(entries.map(\.outputTokens)),
                cacheReadTokens: self.sum(entries.map(\.cacheReadTokens)),
                cacheCreationTokens: self.sum(entries.map(\.cacheCreationTokens)),
                totalTokens: self.sum(entries.map(\.totalTokens)) ?? 0,
                totalCostUSD: self.sum(entries.map(\.costUSD)) ?? 0))
    }

    private static func mergeModelBreakdowns(
        _ rows: [ModelBreakdown]) -> [CostUsageDailyReport.ModelBreakdown]
    {
        struct Accumulator {
            var tokens: [Int?] = []
            var costs: [Double?] = []
        }

        var models: [String: Accumulator] = [:]
        for row in rows {
            let componentTotal = self.sum([
                row.inputTokens,
                row.outputTokens,
                row.cacheReadTokens,
                row.cacheCreationTokens,
            ])
            models[row.modelName, default: Accumulator()].tokens.append(row.totalTokens ?? componentTotal)
            models[row.modelName, default: Accumulator()].costs.append(row.cost)
        }
        return models.keys.sorted().map { modelName in
            let accumulator = models[modelName] ?? Accumulator()
            return CostUsageDailyReport.ModelBreakdown(
                modelName: modelName,
                costUSD: self.sum(accumulator.costs),
                totalTokens: self.sum(accumulator.tokens))
        }
    }

    private static func isAtLeastAsComplete(
        _ fallback: CostUsageDailyReport,
        as native: CostUsageDailyReport) -> Bool
    {
        let fallbackTokens = fallback.summary?.totalTokens ?? self.totalTokens(in: fallback)
        let nativeTokens = native.summary?.totalTokens ?? self.totalTokens(in: native)
        return fallbackTokens >= nativeTokens
    }

    private static func totalTokens(in report: CostUsageDailyReport) -> Int {
        report.data.reduce(0) { partial, entry in
            partial + (entry.totalTokens ?? 0)
        }
    }

    private static func componentTotal(for agent: Agent) -> Int? {
        self.sum([
            agent.inputTokens,
            agent.outputTokens,
            agent.cacheReadTokens,
            agent.cacheCreationTokens,
        ])
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
    }

    private static func sum(_ values: [Int?]) -> Int? {
        let values = values.compactMap(\.self)
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { partial, value in
            let addition = partial.addingReportingOverflow(max(0, value))
            return addition.overflow ? Int.max : addition.partialValue
        }
    }

    private static func sum(_ values: [Double?]) -> Double? {
        let values = values.compactMap(\.self)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private static func failureReason(for error: Error) -> String {
        if error is DecodingError {
            return "invalid-json"
        }
        switch error {
        case is SubprocessRunnerError:
            return "subprocess-failed"
        default:
            return "unexpected-error"
        }
    }
}
