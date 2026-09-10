import Foundation

/// A path-free, account-free report. Values retain the originating host's calendar and pricing.
public struct RemoteCostSummary: Codable, Sendable, Equatable {
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

    public init(snapshot: CostUsageTokenSnapshot, provider: UsageProvider, calendar: Calendar) {
        self.provider = provider.rawValue
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

    package func validate(provider: UsageProvider, historyDays: Int) throws {
        guard RemoteCostFetcher.supportedProviders.contains(provider),
              self.provider == provider.rawValue,
              self.historyDays == historyDays,
              TimeZone(identifier: self.bucketTimeZone) != nil,
              self.currencyCode == "USD",
              [self.coverage.priced, self.coverage.unpriced, self.coverage.unmetered, self.coverage.estimated]
                  .allSatisfy({ $0 >= 0 }),
                  [self.sessionTokens, self.last30DaysTokens].compactMap(\.self).allSatisfy({ $0 >= 0 }),
                  [self.sessionCostUSD, self.last30DaysCostUSD].compactMap(\.self)
                      .allSatisfy({ $0.isFinite && $0 >= 0 })
        else { throw RemoteCostError.invalidReport }
    }
}

public struct RemoteHostCostReport: Codable, Sendable, Equatable, Identifiable {
    public let host: String
    public let provider: String
    public let source: String
    public let summary: RemoteCostSummary?
    public let error: String?

    public var id: String {
        "\(self.source):\(self.host):\(self.provider)"
    }

    public init(
        host: String,
        provider: UsageProvider,
        source: String = "ssh",
        summary: RemoteCostSummary?,
        error: String? = nil)
    {
        self.host = host
        self.provider = provider.rawValue
        self.source = source
        self.summary = summary
        self.error = error
    }
}

public enum RemoteCostError: LocalizedError {
    case invalidHost
    case invalidProvider
    case invalidReport
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Enter an SSH host alias or user@host (up to eight hosts)."
        case .invalidProvider:
            "Remote cost reports support Codex and Claude only."
        case .invalidReport:
            "The remote CLI returned an invalid cost summary. Update CodexBar on that host."
        case .unavailable:
            "Could not read remote costs. Check SSH and that the remote CodexBar CLI supports --summary-only."
        }
    }
}

public struct RemoteCostFetcher: Sendable {
    /// Provider-specific by design: only native Claude and Codex history scanners support the remote summary contract.
    public static let supportedProviders: [UsageProvider] = [.codex, .claude]

    package typealias Runner = @Sendable ([String], [String: String]) async throws -> String
    private let runner: Runner

    public init() {
        self.runner = { arguments, environment in
            let binary = ["/usr/bin/ssh", "/bin/ssh"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
            guard let binary else { throw RemoteCostError.unavailable }
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: environment,
                timeout: 60,
                maxOutputBytes: 16384,
                acceptsNonZeroExit: true,
                label: "fetch remote Claude and Codex costs")
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
        }) else { throw RemoteCostError.invalidHost }
        return RemoteSessionFetcher.sanitizedHosts(parts)
    }

    package static func validatedProviders(_ providers: [UsageProvider]) throws -> [UsageProvider] {
        var seen = Set<String>()
        let normalized = providers.filter { seen.insert($0.rawValue).inserted }
        guard !normalized.isEmpty, normalized.allSatisfy(self.supportedProviders.contains) else {
            throw RemoteCostError.invalidProvider
        }
        return normalized
    }

    package static func arguments(
        host: String,
        providers: [UsageProvider],
        historyDays: Int,
        force: Bool) throws -> [String]
    {
        guard try self.hosts(from: host) == [host], (1...365).contains(historyDays) else {
            throw RemoteCostError.invalidHost
        }
        let providers = try self.validatedProviders(providers)
        let providerArgument = providers.count == 2 ? "both" : providers[0].rawValue
        let options =
            "cost --provider \(providerArgument) --format json --summary-only --provider-native-only " +
            "--days \(historyDays)" + (force ? " --refresh" : "")
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
        providers requestedProviders: [UsageProvider],
        historyDays: Int,
        force: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> [RemoteCostSummary]
    {
        let providers = try Self.validatedProviders(requestedProviders)
        let arguments = try Self.arguments(
            host: host,
            providers: providers,
            historyDays: historyDays,
            force: force)
        let output: String
        do {
            output = try await self.runner(arguments, environment)
        } catch {
            try Task.checkCancellation()
            throw RemoteCostError.unavailable
        }
        try Task.checkCancellation()
        // Never retain raw subprocess output or report a remote stderr message in the UI.
        guard output.utf8.count <= 16384 else { throw RemoteCostError.invalidReport }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteCostError.unavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let reports = try? decoder.decode([RemoteCostSummary].self, from: Data(output.utf8)),
              reports.count <= providers.count
        else { throw RemoteCostError.invalidReport }

        let reportsByProvider = Dictionary(grouping: reports, by: \.provider)
        let requestedProviderIDs = Set(providers.map(\.rawValue))
        guard reportsByProvider.values.allSatisfy({ $0.count == 1 }),
              Set(reportsByProvider.keys).isSubset(of: requestedProviderIDs)
        else {
            throw RemoteCostError.invalidReport
        }
        return try providers.compactMap { provider in
            guard let report = reportsByProvider[provider.rawValue]?.first else { return nil }
            try report.validate(provider: provider, historyDays: historyDays)
            return report
        }
    }
}
