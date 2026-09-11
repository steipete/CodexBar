import Foundation

/// A path-free, account-free report. Values retain the originating host's calendar and pricing.
public struct CodexCostSummary: Codable, Sendable, Equatable {
    public let provider: String
    public let updatedAt: Date
    public let bucketTimeZone: String
    public let currencyCode: String
    public let historyDays: Int
    public let historyCoverageIsEstablished: Bool
    public let provenance: CostProvenance
    public let coverage: CostUsageCoverageCounts
    public let sessionTokens: Int?
    public let sessionCostUSD: Double?
    public let last30DaysTokens: Int?
    public let last30DaysCostUSD: Double?

    public init(snapshot: CostUsageTokenSnapshot, calendar: Calendar) {
        // Provider-specific by design: this transport schema represents native Codex cost history.
        self.provider = "codex"
        self.updatedAt = snapshot.updatedAt
        self.bucketTimeZone = calendar.timeZone.identifier
        self.currencyCode = snapshot.currencyCode
        self.historyDays = snapshot.historyDays
        self.historyCoverageIsEstablished = snapshot.historyCoverageIsEstablished
        let window = snapshot.summary(forLastDays: snapshot.historyDays, calendar: calendar)
        self.provenance = window.provenance
        self.coverage = window.coverage
        self.sessionTokens = snapshot.sessionTokens
        self.sessionCostUSD = snapshot.sessionCostUSD
        self.last30DaysTokens = snapshot.last30DaysTokens
        self.last30DaysCostUSD = snapshot.last30DaysCostUSD
    }

    package func validate(historyDays: Int) throws {
        // Provider-specific by design: reject a different provider before treating the report as Codex history.
        guard self.provider == "codex",
              self.historyDays == historyDays,
              TimeZone(identifier: self.bucketTimeZone) != nil,
              self.currencyCode == "USD",
              [self.coverage.priced, self.coverage.unpriced, self.coverage.unmetered, self.coverage.estimated]
                  .allSatisfy({ $0 >= 0 }),
                  [self.sessionTokens, self.last30DaysTokens].compactMap(\.self).allSatisfy({ $0 >= 0 }),
                  [self.sessionCostUSD, self.last30DaysCostUSD].compactMap(\.self)
                      .allSatisfy({ $0.isFinite && $0 >= 0 })
        else { throw RemoteCodexCostError.invalidReport }
    }
}

public struct CodexHostCostReport: Codable, Sendable, Equatable, Identifiable {
    public let host: String
    public let source: String
    public let summary: CodexCostSummary?
    public let error: String?

    public var id: String {
        "\(self.source):\(self.host)"
    }

    public init(host: String, source: String = "ssh", summary: CodexCostSummary?, error: String? = nil) {
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
            "Enter an SSH host alias or user@host (up to eight hosts)."
        case .invalidReport:
            "The remote CLI returned an invalid cost summary. Update CodexBar on that host."
        case .unavailable:
            "Could not read remote costs. Check SSH and that the remote CodexBar CLI supports --summary-only."
        }
    }
}

public struct RemoteCodexCostFetcher: Sendable {
    package typealias Runner = @Sendable ([String], [String: String]) async throws -> String
    private let runner: Runner

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
                label: "fetch remote Codex costs")
            return result.stdout
        }
    }

    package init(runner: @escaping Runner) {
        self.runner = runner
    }

    public static func hosts(from value: String) throws -> [String] {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let allowed =
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:%[]")
        guard parts.count <= 8, parts.allSatisfy({ host in
            !host.isEmpty && !host.hasPrefix("-") && host.utf8.count <= 255 &&
                host.unicodeScalars.allSatisfy(allowed.contains)
        }) else { throw RemoteCodexCostError.invalidHost }
        return RemoteSessionFetcher.sanitizedHosts(parts)
    }

    package static func arguments(host: String, historyDays: Int, force: Bool) throws -> [String] {
        guard try self.hosts(from: host) == [host], (1...365).contains(historyDays) else {
            throw RemoteCodexCostError.invalidHost
        }
        let options =
            "cost --provider codex --format json --summary-only --provider-native-only --days \(historyDays)" +
            (force ? " --refresh" : "")
        // Choose the executable before running it: a failed scan must not trigger a second scan via a fallback.
        let command = "if command -v codexbar >/dev/null 2>&1; then exec codexbar \(options); " +
            "else exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI \(options); fi"
        return [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T", host,
            "sh", "-lc", "'\(command)'",
        ]
    }

    public func fetch(
        host: String,
        historyDays: Int,
        force: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> CodexCostSummary
    {
        let arguments = try Self.arguments(host: host, historyDays: historyDays, force: force)
        let output: String
        do {
            output = try await self.runner(arguments, environment)
        } catch {
            try Task.checkCancellation()
            throw RemoteCodexCostError.unavailable
        }
        try Task.checkCancellation()
        // Never retain raw subprocess output or report a remote stderr message in the UI.
        guard output.utf8.count <= 16384 else { throw RemoteCodexCostError.invalidReport }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let reports = try? decoder.decode([CodexCostSummary].self, from: Data(output.utf8)),
              reports.count == 1, let report = reports.first
        else { throw RemoteCodexCostError.invalidReport }
        try report.validate(historyDays: historyDays)
        return report
    }
}
