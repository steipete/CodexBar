import Foundation

/// A narrow host-owned total: no account labels, project paths, model rows, or session content.
public struct CodexHostCostWindow: Codable, Sendable, Equatable {
    public let totalTokens: Int?
    public let costUSD: Double?
    public let incompleteRequestCount: Int
    public let coverage: CostUsageCoverageCounts
    public let provenance: CostProvenance

    init(tokens: Int?, costUSD: Double?, window: CostUsageWindowSummary) {
        self.totalTokens = tokens
        self.costUSD = costUSD
        self.incompleteRequestCount = window.incompleteRequestCount
        self.coverage = window.coverage
        self.provenance = window.provenance
    }

    func validate() throws {
        guard self.totalTokens.map({ $0 >= 0 }) ?? true,
              self.costUSD.map({ $0.isFinite && $0 >= 0 }) ?? true,
              self.incompleteRequestCount >= 0
        else { throw RemoteCodexCostError.invalidReport }
        var count = 0
        for category in [
            self.coverage.priced,
            self.coverage.unpriced,
            self.coverage.unmetered,
            self.coverage.estimated,
        ] {
            let sum = count.addingReportingOverflow(category)
            guard category >= 0, !sum.overflow else { throw RemoteCodexCostError.invalidReport }
            count = sum.partialValue
        }
    }
}

/// Versioned, path-free transport. Each host retains its own day boundaries and pricing provenance.
public struct CodexCostSummary: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let provider: String
    public let updatedAt: Date
    public let bucketTimeZone: String
    public let currencyCode: String
    public let historyDays: Int
    public let historyCoverageIsEstablished: Bool
    public let today: CodexHostCostWindow
    public let history: CodexHostCostWindow

    public init(snapshot: CostUsageTokenSnapshot, calendar: Calendar) {
        self.schemaVersion = 1
        self.provider = "codex"
        self.updatedAt = snapshot.updatedAt
        self.bucketTimeZone = calendar.timeZone.identifier
        self.currencyCode = snapshot.currencyCode
        self.historyDays = snapshot.historyDays
        self.historyCoverageIsEstablished = snapshot.historyCoverageIsEstablished
        self.today = CodexHostCostWindow(
            tokens: snapshot.sessionTokens,
            costUSD: snapshot.sessionCostUSD,
            window: snapshot.summary(forLastDays: 1, calendar: calendar))
        self.history = CodexHostCostWindow(
            tokens: snapshot.last30DaysTokens,
            costUSD: snapshot.last30DaysCostUSD,
            window: snapshot.summary(forLastDays: snapshot.historyDays, calendar: calendar))
    }

    public func validate(historyDays: Int) throws {
        guard self.schemaVersion == 1, self.provider == "codex",
              (1...365).contains(historyDays), self.historyDays == historyDays,
              TimeZone(identifier: self.bucketTimeZone) != nil, self.currencyCode == "USD",
              self.updatedAt.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(self.updatedAt.timeIntervalSince1970)
        else { throw RemoteCodexCostError.invalidReport }
        try self.today.validate()
        try self.history.validate()
    }
}

public struct CodexHostCostReport: Codable, Sendable, Equatable {
    public let host: String
    public let source: String
    public let summary: CodexCostSummary?
    public let error: String?

    public init(host: String, source: String, summary: CodexCostSummary?, error: String? = nil) {
        self.host = host
        self.source = source
        self.summary = summary
        self.error = error
    }
}

public enum RemoteCodexCostError: LocalizedError {
    case invalidHost
    case invalidReport
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Enter one SSH host alias or user@host."
        case .invalidReport:
            "The remote CLI returned an unsupported or invalid cost summary. Update CodexBar on that host."
        case .unavailable:
            "Could not read remote costs. Check SSH and that the remote CodexBar CLI supports --summary-only."
        }
    }
}

/// The manual report can retain aggregate-only hosts without inventing daily buckets.
public enum RemoteCodexCostReport: Sendable, Equatable {
    case daily(CodexCostDailySummary)
    case summary(CodexCostSummary)
}

public struct RemoteCodexCostFetcher: Sendable {
    package typealias Runner = @Sendable ([String], [String: String]) async throws -> String
    package typealias BoundedRunner = @Sendable ([String], [String: String], Int) async throws -> SubprocessResult
    private let runner: BoundedRunner
    package static let maximumOutputBytes = 16 * 1024
    package static let maximumDailyOutputBytes = 256 * 1024
    package static let dailyReportMarker = "CODEXBAR_REMOTE_COST_MODE=daily"
    package static let summaryReportMarker = "CODEXBAR_REMOTE_COST_MODE=summary"

    public init() {
        self.runner = { arguments, environment, maximumOutputBytes in
            let binary = ["/usr/bin/ssh", "/bin/ssh"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
            guard let binary else { throw RemoteCodexCostError.unavailable }
            return try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: environment,
                timeout: 60,
                maxOutputBytes: maximumOutputBytes,
                standardInput: FileHandle.nullDevice,
                label: "fetch remote Codex costs")
        }
    }

    package init(runner: @escaping Runner) {
        self.runner = { arguments, environment, _ in
            try await .init(stdout: runner(arguments, environment), stderr: "")
        }
    }

    package init(boundedRunner: @escaping BoundedRunner) {
        self.runner = boundedRunner
    }

    public static func validateHost(_ host: String) throws {
        let allowed =
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:%[]")
        guard !host.isEmpty, !host.hasPrefix("-"), host.utf8.count <= 255,
              host.unicodeScalars.allSatisfy(allowed.contains)
        else { throw RemoteCodexCostError.invalidHost }
    }

    package static func arguments(host: String, historyDays: Int, force: Bool) throws -> [String] {
        try self.validateHost(host)
        return try self.sshArguments(host: host, options: self.summaryOptions(historyDays: historyDays, force: force))
    }

    private static func summaryOptions(historyDays: Int, force: Bool) throws -> String {
        guard (1...365).contains(historyDays) else { throw RemoteCodexCostError.invalidReport }
        return
            "cost --provider codex --format json --summary-only --provider-native-only --days \(historyDays)" +
            (force ? " --refresh" : "")
    }

    package static func dailyArguments(
        host: String,
        historyDays: Int,
        bucketTimeZone: String,
        force: Bool) throws -> [String]
    {
        try self.validateHost(host)
        return try self.sshArguments(host: host, options: self.dailyOptions(
            historyDays: historyDays, bucketTimeZone: bucketTimeZone, force: force))
    }

    private static func dailyOptions(historyDays: Int, bucketTimeZone: String, force: Bool) throws -> String {
        guard (1...365).contains(historyDays) else { throw RemoteCodexCostError.invalidReport }
        let calendar = try CodexCostDailySummary.calendar(bucketTimeZone: bucketTimeZone)
        // The validated zone contains no quotes or shell substitutions, and remains one argument.
        return "cost --provider codex --format json --daily-summary --provider-native-only" +
            " --days \(historyDays) --bucket-time-zone \"\(calendar.timeZone.identifier)\"" +
            (force ? " --refresh" : "")
    }

    private static func sshArguments(host: String, options: String) -> [String] {
        // Select the executable before scanning: a failed scan must never invoke a fallback scan.
        let command = "if command -v codexbar >/dev/null 2>&1; then exec codexbar \(options); " +
            "else exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI \(options); fi"
        return self.sshCommandArguments(host: host, command: command)
    }

    private static func sshCommandArguments(host: String, command: String) -> [String] {
        [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
            "-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes", "-T", "-n", "--", host,
            "sh", "-lc", "'\(command)'",
        ]
    }

    package static func reportArguments(
        host: String,
        historyDays: Int,
        bucketTimeZone: String,
        force: Bool) throws -> [String]
    {
        // Reuse validation and the exact existing commands; capability selection never retries a scan.
        try self.validateHost(host)
        let dailyOptions = try self.dailyOptions(
            historyDays: historyDays, bucketTimeZone: bucketTimeZone, force: force)
        let summaryOptions = try self.summaryOptions(historyDays: historyDays, force: force)
        // The sentinel preserves trailing newlines until the byte bound has been checked.
        let command = """
        if command -v codexbar >/dev/null 2>&1; then cli=codexbar; \
        else cli=/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI; fi; \
        LC_ALL=C; export LC_ALL; help=$("$cli" cost --help 2>/dev/null && printf ".") || exit 1; \
        [ ${#help} -le \(Self.maximumOutputBytes + 1) ] || exit 1; help=${help%.}; \
        daily=0; zone=0; summary=0; set -f; \
        for flag in $help; do case "$flag" in \
        --daily-summary) daily=1 ;; --bucket-time-zone) zone=1 ;; --summary-only) summary=1 ;; esac; done; \
        if [ "$daily" = 1 ] && [ "$zone" = 1 ]; then \
        printf "%s\\n" "\(Self.dailyReportMarker)" >&2; exec "$cli" \(dailyOptions); \
        elif [ "$summary" = 1 ]; then \
        printf "%s\\n" "\(Self.summaryReportMarker)" >&2; exec "$cli" \(summaryOptions); else exit 1; fi
        """
        return self.sshCommandArguments(host: host, command: command)
    }

    public func fetch(
        host: String,
        historyDays: Int,
        force: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> CodexCostSummary
    {
        try Task.checkCancellation()
        let arguments = try Self.arguments(host: host, historyDays: historyDays, force: force)
        let output = try await self.run(
            arguments,
            environment: environment,
            maximumOutputBytes: Self.maximumOutputBytes).stdout
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let reports = try? decoder.decode([CodexCostSummary].self, from: Data(output.utf8)),
              reports.count == 1, let report = reports.first
        else { throw RemoteCodexCostError.invalidReport }
        try report.validate(historyDays: historyDays)
        return report
    }

    public func fetchDaily(
        host: String,
        historyDays: Int,
        bucketTimeZone: String,
        force: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> CodexCostDailySummary
    {
        try Task.checkCancellation()
        let arguments = try Self.dailyArguments(
            host: host, historyDays: historyDays, bucketTimeZone: bucketTimeZone, force: force)
        let output = try await self.run(
            arguments, environment: environment, maximumOutputBytes: Self.maximumDailyOutputBytes).stdout
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let reports = try? decoder.decode([CodexCostDailySummary].self, from: Data(output.utf8)),
              reports.count == 1, let report = reports.first
        else { throw RemoteCodexCostError.invalidReport }
        try report.validate(historyDays: historyDays, bucketTimeZone: bucketTimeZone)
        return report
    }

    public func fetchReport(
        host: String,
        historyDays: Int,
        bucketTimeZone: String,
        force: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> RemoteCodexCostReport
    {
        try Task.checkCancellation()
        let arguments = try Self.reportArguments(
            host: host, historyDays: historyDays, bucketTimeZone: bucketTimeZone, force: force)
        let result = try await self.run(
            arguments, environment: environment, maximumOutputBytes: Self.maximumDailyOutputBytes)
        let output = result.stdout
        // Only our fixed shell metadata identifies capability; arbitrary SSH/CLI diagnostics stay private.
        let markers = result.stderr.split(separator: "\n").filter {
            $0 == Self.dailyReportMarker || $0 == Self.summaryReportMarker
        }
        guard markers.count == 1, let marker = markers.first else { throw RemoteCodexCostError.invalidReport }
        let data = Data(output.utf8)
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              objects.count == 1, let object = objects.first
        else { throw RemoteCodexCostError.invalidReport }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if marker == Self.dailyReportMarker {
            guard let reports = try? decoder.decode([CodexCostDailySummary].self, from: data),
                  let report = reports.first
            else { throw RemoteCodexCostError.invalidReport }
            try report.validate(historyDays: historyDays, bucketTimeZone: bucketTimeZone)
            try Task.checkCancellation()
            return .daily(report)
        }
        guard object["kind"] == nil, object["daily"] == nil,
              output.utf8.count <= Self.maximumOutputBytes,
              result.stderr.utf8.count <= Self.maximumOutputBytes,
              let reports = try? decoder.decode([CodexCostSummary].self, from: data),
              let report = reports.first
        else { throw RemoteCodexCostError.invalidReport }
        try report.validate(historyDays: historyDays)
        try Task.checkCancellation()
        return .summary(report)
    }

    private func run(
        _ arguments: [String],
        environment: [String: String],
        maximumOutputBytes: Int) async throws -> SubprocessResult
    {
        let allowedEnvironment = Set(["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "SSH_AUTH_SOCK"])
        let result: SubprocessResult
        do {
            result = try await self.runner(
                arguments, environment.filter { allowedEnvironment.contains($0.key) }, maximumOutputBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw RemoteCodexCostError.unavailable
        }
        try Task.checkCancellation()
        guard result.stdout.utf8.count <= maximumOutputBytes,
              result.stderr.utf8.count <= maximumOutputBytes
        else { throw RemoteCodexCostError.invalidReport }
        return result
    }
}
