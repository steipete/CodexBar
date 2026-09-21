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

public struct RemoteCodexCostFetcher: Sendable {
    package typealias Runner = @Sendable ([String], [String: String]) async throws -> String
    private let runner: Runner
    package static let maximumOutputBytes = 16 * 1024

    public init() {
        self.runner = { arguments, environment in
            let binary = ["/usr/bin/ssh", "/bin/ssh"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
            guard let binary else { throw RemoteCodexCostError.unavailable }
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: environment,
                timeout: 60,
                maxOutputBytes: Self.maximumOutputBytes,
                standardInput: FileHandle.nullDevice,
                label: "fetch remote Codex costs")
            return result.stdout
        }
    }

    package init(runner: @escaping Runner) {
        self.runner = runner
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
        guard (1...365).contains(historyDays) else { throw RemoteCodexCostError.invalidReport }
        let options =
            "cost --provider codex --format json --summary-only --provider-native-only --days \(historyDays)" +
            (force ? " --refresh" : "")
        // Select the executable before scanning: a failed scan must never invoke a fallback scan.
        let command = "if command -v codexbar >/dev/null 2>&1; then exec codexbar \(options); " +
            "else exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI \(options); fi"
        return [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
            "-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes", "-T", "-n", "--", host,
            "sh", "-lc", "'\(command)'",
        ]
    }

    public func fetch(
        host: String,
        historyDays: Int,
        force: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> CodexCostSummary
    {
        try Task.checkCancellation()
        let arguments = try Self.arguments(host: host, historyDays: historyDays, force: force)
        let allowedEnvironment = Set(["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "SSH_AUTH_SOCK"])
        let output: String
        do {
            output = try await self.runner(arguments, environment.filter { allowedEnvironment.contains($0.key) })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw RemoteCodexCostError.unavailable
        }
        try Task.checkCancellation()
        guard output.utf8.count <= Self.maximumOutputBytes else { throw RemoteCodexCostError.invalidReport }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let reports = try? decoder.decode([CodexCostSummary].self, from: Data(output.utf8)),
              reports.count == 1, let report = reports.first
        else { throw RemoteCodexCostError.invalidReport }
        try report.validate(historyDays: historyDays)
        return report
    }
}
