import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIAttributionBatchTests {
    @Test
    func `batch attribution preserves uniquely matched concurrent proxy requests`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let otherTokens = CLIProxyAPIAttributionResolver.TokenSignature(
            input: 100,
            cacheRead: 300,
            cacheCreate: 400,
            output: 200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
                .init(
                    sessionID: "session-2",
                    model: "gpt-5.5",
                    timestamp: timestamp.addingTimeInterval(2)),
            ],
            usageRecords: [
                Self.record(
                    timestamp: timestamp.addingTimeInterval(1),
                    provider: "codex",
                    authType: "oauth"),
                Self.record(
                    timestamp: timestamp.addingTimeInterval(3),
                    provider: "openrouter",
                    authType: "api_key",
                    tokens: otherTokens),
            ])
        let requests = [
            CLIProxyAPIAttributionResolver.Request(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "session-1",
                timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
                tokens: Self.tokens),
            CLIProxyAPIAttributionResolver.Request(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "session-2",
                timestampUnixMs: Int64(timestamp.addingTimeInterval(2).timeIntervalSince1970 * 1000),
                tokens: otherTokens),
        ]

        let attributions = resolver.attributions(for: requests)

        #expect(attributions.map(\.upstream?.provider) == ["codex", "openrouter"])
        #expect(attributions.allSatisfy { $0.evidence.contains(.cliProxyUsageTelemetry) })
    }

    @Test
    func `batch attribution uses unique timestamps for concurrent requests with equal tokens`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "session-1", model: "gpt-5.5", timestamp: timestamp),
                .init(
                    sessionID: "session-2",
                    model: "gpt-5.5",
                    timestamp: timestamp.addingTimeInterval(4)),
            ],
            usageRecords: [
                Self.record(timestamp: timestamp, provider: "codex", authType: "oauth"),
                Self.record(
                    timestamp: timestamp.addingTimeInterval(4),
                    provider: "openrouter",
                    authType: "api_key"),
            ])
        let attributions = resolver.attributions(for: [
            .init(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "session-1",
                timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
                tokens: Self.tokens),
            .init(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "session-2",
                timestampUnixMs: Int64(timestamp.addingTimeInterval(4).timeIntervalSince1970 * 1000),
                tokens: Self.tokens),
        ])

        #expect(attributions.map(\.upstream?.provider) == ["codex", "openrouter"])
    }

    @Test
    func `batch route evidence belongs only to the closest request in a resumed session`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "resumed-session", model: "gpt-5.5", timestamp: timestamp),
            ])
        let attributions = resolver.attributions(for: [
            .init(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "resumed-session",
                timestampUnixMs: Int64(timestamp.addingTimeInterval(1).timeIntervalSince1970 * 1000),
                tokens: Self.tokens),
            .init(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "resumed-session",
                timestampUnixMs: Int64(timestamp.addingTimeInterval(30).timeIntervalSince1970 * 1000),
                tokens: Self.tokens),
        ])

        #expect(attributions.map(\.route) == [.cliProxyAPI, .unknown])
        #expect(attributions[0].evidence.contains(.cliProxyRequestLog))
        #expect(!attributions[1].evidence.contains(.cliProxyRequestLog))
    }

    @Test
    func `orphaned route evidence does not claim a later sole request`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "resumed-session", model: "gpt-5.5", timestamp: timestamp),
            ])
        let attribution = resolver.attributions(for: [
            .init(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "resumed-session",
                timestampUnixMs: Int64(timestamp.addingTimeInterval(30 * 60).timeIntervalSince1970 * 1000),
                tokens: Self.tokens),
        ])[0]

        #expect(attribution.route == .unknown)
        #expect(!attribution.evidence.contains(.cliProxyRequestLog))
    }

    @Test
    func `orphaned route evidence does not claim the closest of multiple later requests`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "resumed-session", model: "gpt-5.5", timestamp: timestamp),
            ])
        let attributions = resolver.attributions(for: [
            .init(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "resumed-session",
                timestampUnixMs: Int64(timestamp.addingTimeInterval(30 * 60).timeIntervalSince1970 * 1000),
                tokens: Self.tokens),
            .init(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "resumed-session",
                timestampUnixMs: Int64(timestamp.addingTimeInterval(40 * 60).timeIntervalSince1970 * 1000),
                tokens: Self.tokens),
        ])

        #expect(attributions.map(\.route) == [.unknown, .unknown])
        #expect(attributions.allSatisfy { !$0.evidence.contains(.cliProxyRequestLog) })
    }

    @Test
    func `uniquely matched telemetry confirms both requests sharing one route observation`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        let otherTokens = CLIProxyAPIAttributionResolver.TokenSignature(
            input: 100,
            cacheRead: 300,
            cacheCreate: 400,
            output: 200)
        let resolver = CLIProxyAPIAttributionResolver(
            observations: [
                .init(sessionID: "resumed-session", model: "gpt-5.5", timestamp: timestamp),
            ],
            usageRecords: [
                Self.record(timestamp: timestamp, provider: "codex", authType: "oauth"),
                Self.record(
                    timestamp: timestamp.addingTimeInterval(1),
                    provider: "openrouter",
                    authType: "api_key",
                    tokens: otherTokens),
            ])
        let attributions = resolver.attributions(for: [
            .init(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "resumed-session",
                timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
                tokens: Self.tokens),
            .init(
                model: "gpt-5.5",
                modelProvider: .openAI,
                sessionID: "resumed-session",
                timestampUnixMs: Int64(timestamp.addingTimeInterval(1).timeIntervalSince1970 * 1000),
                tokens: otherTokens),
        ])

        #expect(attributions.map(\.route) == [.cliProxyAPI, .cliProxyAPI])
        #expect(attributions.map(\.upstream?.provider) == ["codex", "openrouter"])
        #expect(attributions.allSatisfy { $0.evidence.contains(.cliProxyUsageTelemetry) })
        #expect(attributions.count(where: { $0.evidence.contains(.cliProxyRequestLog) }) == 1)
    }

    private static let tokens = CLIProxyAPIAttributionResolver.TokenSignature(
        input: 10,
        cacheRead: 30,
        cacheCreate: 40,
        output: 20)

    private static func record(
        timestamp: Date,
        provider: String,
        authType: String,
        tokens: CLIProxyAPIAttributionResolver.TokenSignature = Self.tokens) -> CLIProxyAPIUsageRecord
    {
        CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: provider,
            executorType: provider == "codex" ? "CodexExecutor" : "OpenAICompatExecutor",
            model: "gpt-5.5",
            alias: "gpt-5.5",
            endpoint: "POST /v1/messages",
            authType: authType,
            requestID: "request-\(provider)-\(timestamp.timeIntervalSince1970)",
            tokens: .init(
                input: tokens.input,
                output: tokens.output,
                cacheRead: tokens.cacheRead,
                cacheCreation: tokens.cacheCreate,
                total: tokens.input + tokens.output + tokens.cacheRead + tokens.cacheCreate))
    }
}
