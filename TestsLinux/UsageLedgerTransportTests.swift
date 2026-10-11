import Foundation
import Testing
@testable import CodexBarCore

struct UsageLedgerTransportTests {
    static let now = Date(timeIntervalSince1970: 1_788_177_600.123)
    static let calendar = CostUsageBucketTimeZone.calendar(identifier: "America/New_York")

    @Test
    func `SSH uses fixed trusted arguments and strips unrelated environment secrets`() async throws {
        let expectedArguments = try RemoteUsageLedgerFetcher.arguments(
            host: "BuildUser@fixture-host", provider: "codex", historyDays: 1,
            now: Self.now, calendar: Self.calendar)
        #expect(expectedArguments == [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes",
            "-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes", "-T", "-n", "--", "BuildUser@fixture-host", "sh", "-lc",
            "'if command -v codexbar >/dev/null 2>&1; then exec codexbar cost --provider codex --format json " +
                "--ledger-only --days 1 --ledger-time-zone America/New_York --ledger-end 1788177600123; " +
                "else exec /Applications/CodexBar.app/Contents/Helpers/CodexBarCLI cost --provider codex " +
                "--format json --ledger-only --days 1 --ledger-time-zone America/New_York " +
                "--ledger-end 1788177600123; fi'",
        ])
        let wire = try Self.wire(Self.ledger())
        let fetcher = RemoteUsageLedgerFetcher { arguments, environment in
            #expect(arguments == expectedArguments)
            #expect(environment == [
                "PATH": "/fixture/bin",
                "HOME": "/fixture/home",
                "SSH_AUTH_SOCK": "/fixture/agent",
            ])
            #expect(environment["OPENAI_API_KEY"] == nil)
            #expect(environment["ANTHROPIC_API_KEY"] == nil)
            #expect(environment["CODEX_HOME"] == nil)
            return wire
        }
        let result = try await fetcher.fetch(
            host: "BuildUser@fixture-host", provider: .codex, historyDays: 1,
            now: Self.now, calendar: Self.calendar, environment: [
                "PATH": "/fixture/bin", "HOME": "/fixture/home", "SSH_AUTH_SOCK": "/fixture/agent",
                "OPENAI_API_KEY": "fixture-secret", "ANTHROPIC_API_KEY": "fixture-secret",
                "CODEX_HOME": "/fixture/unrelated-profile",
            ])
        #expect(result.provider == "codex")
        #expect(result.records.count == 1)
    }

    @Test
    func `millisecond reporting bounds survive ISO snapshot encoding and integer end reconstruction`() async throws {
        let expected = Self.ledger()
        let wire = try Self.wire(expected)
        let end = Int64((Self.now.timeIntervalSince1970 * 1000).rounded())
        let reconstructed = Date(timeIntervalSince1970: Double(end) / 1000)
        let fetcher = RemoteUsageLedgerFetcher { _, _ in wire }
        let result = try await fetcher.fetch(
            host: "fixture-host", provider: .codex, historyDays: 1,
            now: reconstructed, calendar: Self.calendar, environment: [:])
        #expect(result.windowStartUnixMs == expected.windowStartUnixMs)
        #expect(result.windowEndUnixMs == 1_788_177_600_123)
        #expect(result.records[0].timestampUnixMs == 1_788_177_599_123)
        let args = try RemoteUsageLedgerFetcher.arguments(
            host: "fixture-host", provider: "codex", historyDays: 1,
            now: reconstructed, calendar: Self.calendar)
        #expect(args.last?.contains("--ledger-end 1788177600123") == true)
    }

    @Test(arguments: ["", "-oProxyCommand=bad", "fixture-host other", "host;bad", "host'", "host\nother"])
    func `unsafe SSH host specifications fail before a runner is invoked`(host: String) {
        #expect(throws: RemoteCodexCostError.self) {
            try RemoteUsageLedgerFetcher.arguments(
                host: host, provider: "codex", historyDays: 1, now: Self.now, calendar: Self.calendar)
        }
    }

    @Test(arguments: ["provider", "history", "date"])
    func `invalid requests fail before shell construction`(mutation: String) {
        #expect(throws: UsageLedgerError.self) {
            try RemoteUsageLedgerFetcher.arguments(
                host: "fixture-host", provider: mutation == "provider" ? "unsupported" : "codex",
                historyDays: mutation == "history" ? 366 : 1,
                now: mutation == "date" ? Date(timeIntervalSince1970: .nan) : Self.now,
                calendar: Self.calendar)
        }
    }

    @Test(arguments: ["timezone", "window", "schema", "provider"])
    func `remote responses with invalid or incompatible metadata fail closed`(mutation: String) async throws {
        var ledger = Self.ledger()
        switch mutation {
        case "timezone": ledger.bucketTimeZone = "fixture/unsafe;zone"
        case "window": ledger.windowEndUnixMs -= 1
        case "schema": ledger.schemaVersion = 2
        default: ledger.provider = "claude"
        }
        let wire = try Self.wire(ledger)
        let fetcher = RemoteUsageLedgerFetcher { _, _ in wire }
        await #expect(throws: UsageLedgerError.self) {
            try await fetcher.fetch(
                host: "fixture-host", provider: .codex, historyDays: 1,
                now: Self.now, calendar: Self.calendar, environment: [:])
        }
    }

    @Test
    func `oversized SSH response is rejected before JSON decoding`() async {
        let fetcher = RemoteUsageLedgerFetcher { _, _ in
            String(repeating: " ", count: UsageLedger.maximumOutputBytes + 1)
        }
        await #expect(throws: UsageLedgerError.self) {
            try await fetcher.fetch(
                host: "fixture-host", provider: .codex, historyDays: 1,
                now: Self.now, calendar: Self.calendar, environment: [:])
        }
    }

    @Test
    func `runner cancellation propagates without becoming an unavailable ledger`() async {
        let fetcher = RemoteUsageLedgerFetcher { _, _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await fetcher.fetch(
                host: "fixture-host", provider: .codex, historyDays: 1,
                now: Self.now, calendar: Self.calendar, environment: [:])
        }
    }

    static func ledger() -> UsageLedger {
        let end = Int64((Self.now.timeIntervalSince1970 * 1000).rounded())
        let row = UsageLedgerRecord(
            id: UsageLedgerRecord.digest(["fixture-response"]), identity: .request,
            timestampUnixMs: end - 1000, model: "fixture-model", inputTokens: 100, cacheReadTokens: 0,
            outputTokens: 10, totalTokens: 110, costUSD: 0.25)
        var ledger = UsageLedger(
            provider: "codex", updatedAt: Self.now, historyDays: 1,
            bucketTimeZone: Self.calendar.timeZone.identifier, coverageIsEstablished: true, records: [row])
        ledger.windowEndUnixMs = end
        return ledger
    }

    static func wire(_ ledger: UsageLedger) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try String(decoding: encoder.encode(ledger), as: UTF8.self)
    }
}
