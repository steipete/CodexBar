import Foundation

/// Opt-in, one-host numeric export using the user's already trusted SSH configuration.
public struct RemoteUsageLedgerFetcher: Sendable {
    package typealias Runner = @Sendable ([String], [String: String]) async throws -> String
    private let runner: Runner

    public init() {
        self.runner = { arguments, environment in
            guard let binary = ["/usr/bin/ssh", "/bin/ssh"].first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else { throw UsageLedgerError.invalid("SSH is unavailable.") }
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: environment,
                timeout: 180,
                maxOutputBytes: UsageLedger.maximumOutputBytes,
                standardInput: FileHandle.nullDevice,
                label: "fetch remote native usage ledger")
            return result.stdout
        }
    }

    package init(runner: @escaping Runner) {
        self.runner = runner
    }

    package static func arguments(
        host: String, provider: String, historyDays: Int, now: Date, calendar: Calendar) throws -> [String]
    {
        try RemoteCodexCostFetcher.validateHost(host)
        let zone = calendar.timeZone.identifier
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_+-")
        // Provider-specific by design: SSH invokes the bounded native Codex or Claude ledger protocol only.
        guard ["codex", "claude"].contains(provider), (1...365).contains(historyDays),
              zone.unicodeScalars.allSatisfy(allowed.contains), TimeZone(identifier: zone) != nil,
              now.timeIntervalSince1970.isFinite, (0...253_402_300_799).contains(now.timeIntervalSince1970)
        else { throw UsageLedgerError.invalid("Invalid usage ledger request.") }
        let end = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let options = "cost --provider \(provider) --format json --ledger-only --days \(historyDays) " +
            "--ledger-time-zone \(zone) --ledger-end \(end)"
        let command = "if command -v codexbar >/dev/null 2>&1; then exec codexbar \(options); " +
            "else exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI \(options); fi"
        return [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes",
            "-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes", "-T", "-n", "--", host, "sh", "-lc", "'\(command)'",
        ]
    }

    public func fetch(
        host: String,
        provider: UsageProvider,
        historyDays: Int,
        now: Date,
        calendar: Calendar,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> UsageLedger
    {
        let now = UsageLedgerLoader.canonicalDate(now)
        // Provider-specific by design: Remote protocol names are defined only for Codex and Claude exporters.
        let name = provider == .codex ? "codex" : provider == .claude ? "claude" : "unsupported"
        let arguments = try Self.arguments(
            host: host, provider: name, historyDays: historyDays, now: now, calendar: calendar)
        let allowed = Set(["PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "SSH_AUTH_SOCK"])
        try Task.checkCancellation()
        let output = try await self.runner(arguments, environment.filter { allowed.contains($0.key) })
        try Task.checkCancellation()
        guard output.utf8.count <= UsageLedger.maximumOutputBytes else {
            throw UsageLedgerError.invalid("Remote usage ledger exceeds the size limit.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(UsageLedger.self, from: Data(output.utf8))
        try ledger.validate(provider: name, historyDays: historyDays)
        let start = calendar.date(byAdding: .day, value: 1 - historyDays, to: calendar.startOfDay(for: now))
        guard ledger.bucketTimeZone == calendar.timeZone.identifier,
              ledger.windowEndUnixMs == Int64((now.timeIntervalSince1970 * 1000).rounded()),
              start.map({ Int64($0.timeIntervalSince1970 * 1000) }) == ledger.windowStartUnixMs
        else { throw UsageLedgerError.invalid("Remote usage ledger has a different reporting window.") }
        return ledger
    }
}

public enum UsageLedgerCollector {
    /// Explicit local plus SSH collection; an unavailable source never erases the other source's records.
    public static func collect(
        provider: UsageProvider,
        host: String,
        historyDays: Int = 30,
        calendar: Calendar = .current,
        now: Date = Date()) async throws -> CombinedUsageLedgerReport
    {
        let now = UsageLedgerLoader.canonicalDate(now)
        try RemoteCodexCostFetcher.validateHost(host)
        // Provider-specific by design: Combined histories are restricted to the two native transcript formats.
        guard provider == .codex || provider == .claude else {
            throw UsageLedgerError.invalid("Only native Codex and Claude history is supported.")
        }
        let name = provider == .codex ? "codex" : "claude"
        var reports: [UsageLedgerHostReport] = []
        do {
            let ledger = try await UsageLedgerLoader.load(
                provider: provider, historyDays: historyDays, now: now, calendar: calendar)
            try ledger.validate(provider: name, historyDays: historyDays)
            reports.append(.init(host: "local", ledger: ledger))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            reports.append(.init(host: "local", ledger: nil, error: "Local native history is unavailable."))
        }
        try Task.checkCancellation()
        do {
            let ledger = try await RemoteUsageLedgerFetcher().fetch(
                host: host, provider: provider, historyDays: historyDays, now: now, calendar: calendar)
            reports.append(.init(host: host, ledger: ledger))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            reports.append(.init(
                host: host,
                ledger: nil,
                error: "Remote history unavailable. Check SSH and install a CLI supporting --ledger-only."))
        }
        try Task.checkCancellation()
        return try UsageLedgerMerger.merge(reports: reports, provider: name, historyDays: historyDays)
    }
}
