import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLICostTests {
    @Test
    func `cost json shortcut does not enable json logs`() throws {
        let signature = CodexBarCLI._costSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--json"])

        #expect(parsed.flags.contains("jsonShortcut"))
        #expect(!parsed.flags.contains("jsonOutput"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func `provider native only excludes pi and OMP session mirrors`() throws {
        let parser = CommandParser(signature: CodexBarCLI._costSignatureForTesting())

        let defaultValues = try parser.parse(arguments: [])
        #expect(CodexBarCLI.decodeCostIncludePiSessions(from: defaultValues))

        let nativeOnlyValues = try parser.parse(arguments: ["--provider-native-only"])
        #expect(!CodexBarCLI.decodeCostIncludePiSessions(from: nativeOnlyValues))
    }

    @Test
    func `parses session group by and keeps project parsing`() throws {
        let parser = CommandParser(signature: CodexBarCLI._costSignatureForTesting())

        let sessionValues = try parser.parse(arguments: ["--group-by", "session"])
        #expect(CodexBarCLI._decodeCostGroupByForTesting(from: sessionValues) == .session)

        let projectValues = try parser.parse(arguments: ["--group-by", "project"])
        #expect(CodexBarCLI._decodeCostGroupByForTesting(from: projectValues) == .project)

        let defaultValues = try parser.parse(arguments: [])
        #expect(CodexBarCLI._decodeCostGroupByForTesting(from: defaultValues) == .none)
    }

    @Test
    func `session grouping is codex only in text mode`() {
        let textProviders = CodexBarCLI.costProviders(
            [.claude, .codex],
            groupBy: .session,
            format: .text)
        #expect(textProviders.map(\.rawValue) == ["codex"])

        let jsonProviders = CodexBarCLI.costProviders(
            [.claude, .codex],
            groupBy: .session,
            format: .json)
        #expect(jsonProviders.map(\.rawValue) == ["claude", "codex"])
    }

    @Test
    func `session text grouping disables pi merge only for codex`() {
        #expect(CodexBarCLI.costIncludePiSessions(
            provider: .codex,
            groupBy: .session,
            format: .text,
            includePiSessions: true) == false)
        #expect(CodexBarCLI.costIncludePiSessions(
            provider: .codex,
            groupBy: .session,
            format: .json,
            includePiSessions: true))
        #expect(CodexBarCLI.costIncludePiSessions(
            provider: .codex,
            groupBy: .project,
            format: .text,
            includePiSessions: true))
        #expect(CodexBarCLI.costIncludePiSessions(
            provider: .claude,
            groupBy: .session,
            format: .text,
            includePiSessions: true))
    }

    @Test
    func `session grouping warns when default pi usage is omitted`() {
        #expect(CodexBarCLI.sessionGroupingPiOmissionWarning(
            provider: .codex,
            groupBy: .session,
            format: .text,
            includePiSessions: true)?.contains("Pi/OMP usage is omitted") == true)
        #expect(CodexBarCLI.sessionGroupingPiOmissionWarning(
            provider: .codex,
            groupBy: .session,
            format: .text,
            includePiSessions: false) == nil)
        #expect(CodexBarCLI.sessionGroupingPiOmissionWarning(
            provider: .codex,
            groupBy: .session,
            format: .json,
            includePiSessions: true) == nil)
        #expect(CodexBarCLI.sessionGroupingPiOmissionWarning(
            provider: .claude,
            groupBy: .session,
            format: .text,
            includePiSessions: true) == nil)
    }

    @Test
    func `session grouping falls back for unsupported providers`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .claude, snapshot: snap, groupBy: .session, useColor: false)

        #expect(output.contains("Claude Cost (API-rate estimate)"))
        #expect(!output.contains("Conversations ("))
    }

    @Test
    func `renders Grok as token-only local history`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 120,
            sessionCostUSD: nil,
            last30DaysTokens: 900,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: true,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .grok, snapshot: snap, useColor: false)

        #expect(output.contains("Grok Token History"))
        #expect(output.contains("Today: 120 tokens"))
        #expect(output.contains("Last 30 days: 900 tokens"))
        #expect(output.contains("Subscription credits are a quota, not dollars"))
        #expect(!output.contains("API-rate estimate"))
    }

    @Test
    func `warns when Grok local history is incomplete`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 120,
            sessionCostUSD: nil,
            last30DaysTokens: 900,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .grok, snapshot: snap, useColor: false)

        #expect(output.contains("Local token history is incomplete."))
    }

    @Test
    func `renders codex session grouped cost text`() {
        let sessionDate = Date(timeIntervalSince1970: 1_750_000_000)
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            daily: [],
            sessions: [
                CostUsageSessionBreakdown(
                    sessionID: "abcd12345678abcd12345678abcd12345678",
                    lastActivity: sessionDate,
                    inputTokens: 1_600_000,
                    cachedInputTokens: 200_000,
                    outputTokens: 200_000,
                    totalTokens: 1_800_000,
                    requestCount: 37,
                    costUSD: 4.21,
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 4.21,
                            totalTokens: 1_800_000),
                    ]),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .codex, snapshot: snap, groupBy: .session, useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.contains("Codex API-equivalent estimate (not billed)"))
        #expect(output.contains("Conversations (Last 30 days):"))
        #expect(output.contains("Session abcd...12345678: $4.21 · 1.8M tokens · 37 requests"))
        #expect(output.contains("gpt-5.4 · \(sessionTimestamp(sessionDate))"))
        #expect(output.contains("Not a subscription bill or plan value · local usage × public API prices"))
    }

    @Test
    func `session rows preserve snapshot ordering`() throws {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            daily: [],
            sessions: [
                CostUsageSessionBreakdown(
                    sessionID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    lastActivity: Date(timeIntervalSince1970: 1_750_000_000),
                    inputTokens: nil,
                    cachedInputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 100,
                    requestCount: nil,
                    costUSD: 1.0,
                    modelBreakdowns: []),
                CostUsageSessionBreakdown(
                    sessionID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                    lastActivity: Date(timeIntervalSince1970: 1_751_000_000),
                    inputTokens: nil,
                    cachedInputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 200,
                    requestCount: nil,
                    costUSD: 2.0,
                    modelBreakdowns: []),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .codex, snapshot: snap, groupBy: .session, useColor: false)

        let first = try #require(output.range(of: "Session aaaa...aaaaaaaa"))
        let second = try #require(output.range(of: "Session bbbb...bbbbbbbb"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test
    func `session with unknown cost renders dash not zero`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: nil,
            last30DaysTokens: 9000,
            last30DaysCostUSD: nil,
            historyDays: 30,
            daily: [],
            sessions: [
                CostUsageSessionBreakdown(
                    sessionID: "abcd12345678abcd12345678abcd12345678",
                    lastActivity: Date(timeIntervalSince1970: 1_750_000_000),
                    inputTokens: 800_000,
                    cachedInputTokens: nil,
                    outputTokens: 20000,
                    totalTokens: 820_000,
                    requestCount: 19,
                    costUSD: nil,
                    modelBreakdowns: []),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .codex, snapshot: snap, groupBy: .session, useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.contains("Session abcd...12345678: — · 820K tokens · 19 requests"))
        #expect(!output.contains("$0"))
        #expect(output.contains("Unknown model · "))
    }

    @Test
    func `session with partial data renders compactly`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            daily: [],
            sessions: [
                CostUsageSessionBreakdown(
                    sessionID: "efgh87654321efgh87654321efgh87654321",
                    lastActivity: Date(timeIntervalSince1970: 1_750_000_000),
                    inputTokens: nil,
                    cachedInputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    requestCount: nil,
                    costUSD: 2.17,
                    modelBreakdowns: []),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .codex, snapshot: snap, groupBy: .session, useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.contains("Session efgh...87654321: $2.17"))
        #expect(!output.contains("tokens"))
        #expect(!output.contains("requests"))
        #expect(output.contains("Unknown model · "))
    }

    @Test
    func `session model label stays compact for multiple models`() {
        let sessions = [
            CostUsageSessionBreakdown(
                sessionID: "abcd12345678abcd12345678abcd12345678",
                lastActivity: Date(timeIntervalSince1970: 1_750_000_000),
                inputTokens: nil,
                cachedInputTokens: nil,
                outputTokens: nil,
                totalTokens: 100,
                requestCount: nil,
                costUSD: 1.0,
                modelBreakdowns: [
                    CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.4", costUSD: 0.5, totalTokens: 50),
                    CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.2-codex", costUSD: 0.5, totalTokens: 50),
                ]),
            CostUsageSessionBreakdown(
                sessionID: "efgh87654321efgh87654321efgh87654321",
                lastActivity: Date(timeIntervalSince1970: 1_750_000_000),
                inputTokens: nil,
                cachedInputTokens: nil,
                outputTokens: nil,
                totalTokens: 150,
                requestCount: nil,
                costUSD: 1.5,
                modelBreakdowns: [
                    CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.4", costUSD: 0.5, totalTokens: 50),
                    CostUsageDailyReport.ModelBreakdown(modelName: "gpt-5.2-codex", costUSD: 0.5, totalTokens: 50),
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: "fictitious-model-alpha",
                        costUSD: 0.5,
                        totalTokens: 50),
                ]),
        ]
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            daily: [],
            sessions: sessions,
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .codex, snapshot: snap, groupBy: .session, useColor: false)

        #expect(output.contains("gpt-5.4 +1 model · "))
        #expect(output.contains("gpt-5.4 +2 models · "))
        #expect(!output.contains("fictitious-model-alpha · "))
    }

    @Test
    func `session grouping with no sessions renders empty state`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .codex, snapshot: snap, groupBy: .session, useColor: false)

        #expect(output.contains("Conversations (Last 30 days):\n—\n"))
        #expect(output.contains("Not a subscription bill or plan value · local usage × public API prices"))
    }

    @Test
    func `session grouping labels incomplete history during catch up`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .codex, snapshot: snap, groupBy: .session, useColor: false)

        #expect(output.contains("Conversation history is incomplete while the local scan catches up."))
        #expect(!output.contains("Conversations (Last 30 days):\n—\n"))
    }

    @Test
    func `session grouping labels partial history during catch up`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            daily: [],
            sessions: [
                CostUsageSessionBreakdown(
                    sessionID: "abcd12345678abcd12345678abcd12345678",
                    lastActivity: Date(timeIntervalSince1970: 1_750_000_000),
                    inputTokens: nil,
                    cachedInputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 100,
                    requestCount: 2,
                    costUSD: 0.04,
                    modelBreakdowns: []),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(provider: .codex, snapshot: snap, groupBy: .session, useColor: false)

        #expect(output.contains("Conversation history is incomplete while the local scan catches up."))
        #expect(output.contains("Session abcd...12345678"))
    }

    @Test
    func `session grouping does not change cost JSON payload`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.01,
            last30DaysTokens: 40,
            last30DaysCostUSD: 0.04,
            daily: [],
            sessions: [
                CostUsageSessionBreakdown(
                    sessionID: "abcd12345678abcd12345678abcd12345678",
                    lastActivity: Date(timeIntervalSince1970: 1_750_000_000),
                    inputTokens: 30,
                    cachedInputTokens: nil,
                    outputTokens: 10,
                    totalTokens: 40,
                    requestCount: 2,
                    costUSD: 0.04,
                    modelBreakdowns: []),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let payload = CodexBarCLI.makeCostPayload(provider: .codex, snapshot: snapshot, error: nil)
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode cost payload JSON")
            return
        }

        #expect(!json.contains("\"sessions\""))
    }

    @Test
    func `renders cost text snapshot`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 90,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CodexBarCLI.renderCostText(provider: .claude, snapshot: snap, useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.contains("Claude Cost (API-rate estimate)"))
        #expect(output.contains("Today: $1.25 · 1.2K tokens"))
        #expect(output.contains("Last 90 days: $9.99 · 9K tokens"))
        #expect(output.contains("cache read/write tokens"))
        #expect(output.contains("Claude Code /status"))
    }

    @Test
    func `renders codex project grouped cost text`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            daily: [],
            projects: [
                CostUsageProjectBreakdown(
                    name: "client-a",
                    path: "/work/client-a",
                    totalTokens: 7000,
                    totalCostUSD: 7.5,
                    daily: [],
                    modelBreakdowns: nil,
                    sources: [
                        CostUsageProjectSourceBreakdown(
                            name: "client-a",
                            path: "/work/client-a",
                            totalTokens: 5000,
                            totalCostUSD: 5.25,
                            daily: [],
                            modelBreakdowns: nil),
                        CostUsageProjectSourceBreakdown(
                            name: "client-a",
                            path: "/Users/test/.codex/worktrees/abcd/client-a",
                            totalTokens: 2000,
                            totalCostUSD: 2.25,
                            daily: [],
                            modelBreakdowns: nil),
                    ]),
                CostUsageProjectBreakdown(
                    name: CostUsageProjectBreakdown.unknownProjectName,
                    path: nil,
                    totalTokens: 2000,
                    totalCostUSD: 2.49,
                    daily: [],
                    modelBreakdowns: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CodexBarCLI.renderCostText(
            provider: .codex,
            snapshot: snap,
            groupBy: .project,
            useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.contains("Codex API-equivalent estimate (not billed)"))
        #expect(output.contains("Projects (Last 30 days):"))
        #expect(output.contains("client-a: $7.50 · 7K tokens"))
        #expect(output.contains("/work/client-a"))
        #expect(output.contains("  - client-a: $5.25 · 5K tokens"))
        #expect(output.contains("  - client-a: $2.25 · 2K tokens"))
        #expect(output.contains("/Users/test/.codex/worktrees/abcd/client-a"))
        #expect(output.contains("Unknown project: $2.49 · 2K tokens"))
        #expect(output.contains("Not a subscription bill or plan value · local usage × public API prices"))
    }

    @Test
    func `encodes cost payload JSON`() throws {
        let payload = CostPayload(
            provider: "claude",
            source: "local",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionTokens: 100,
            sessionCostUSD: 0.5,
            historyDays: 90,
            last30DaysTokens: 200,
            last30DaysCostUSD: 1.5,
            daily: [
                CostDailyEntryPayload(
                    date: "2025-12-20",
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheReadTokens: 2,
                    cacheCreationTokens: 3,
                    totalTokens: 15,
                    costUSD: 0.01,
                    modelsUsed: ["claude-sonnet-4-20250514"],
                    modelBreakdowns: [
                        CostModelBreakdownPayload(
                            modelName: "claude-sonnet-4-20250514",
                            costUSD: 0.01,
                            totalTokens: 15),
                    ]),
            ],
            totals: CostTotalsPayload(
                totalInputTokens: 10,
                totalOutputTokens: 5,
                cacheReadTokens: 2,
                cacheCreationTokens: 3,
                totalTokens: 15,
                totalCostUSD: 0.01),
            error: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode cost payload JSON")
            return
        }

        #expect(json.contains("\"provider\":\"claude\""))
        #expect(json.contains("\"source\":\"local\""))
        #expect(json.contains("\"historyDays\":90"))
        #expect(json.contains("\"daily\""))
        #expect(json.contains("\"totals\""))
        #expect(json.contains("\"cacheReadTokens\":2"))
        #expect(json.contains("\"cacheCreationTokens\":3"))
        #expect(json.contains("\"totalCost\""))
        #expect(json.contains("\"totalTokens\":15"))
        #expect(json.contains("1700000000"))
    }

    @Test
    func `cost JSON exposes history coverage as a boolean`() throws {
        for coverage in [false, true] {
            let snapshot = CostUsageTokenSnapshot(
                sessionTokens: 10,
                sessionCostUSD: 0.01,
                last30DaysTokens: 40,
                last30DaysCostUSD: 0.04,
                historyCoverageIsEstablished: coverage,
                daily: [],
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let payload = CodexBarCLI.makeCostPayload(provider: .codex, snapshot: snapshot, error: nil)
            let data = try JSONEncoder().encode(payload)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

            #expect(object.keys.contains("historyCoverageIsEstablished"))
            #expect(object["historyCoverageIsEstablished"] as? Bool == coverage)
        }
    }

    @Test
    func `codex cost payload includes project rollups`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.01,
            last30DaysTokens: 40,
            last30DaysCostUSD: 0.04,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-02",
                    inputTokens: 30,
                    outputTokens: 10,
                    totalTokens: 40,
                    costUSD: 0.04,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 0.04,
                            totalTokens: 40),
                    ]),
            ],
            projects: [
                CostUsageProjectBreakdown(
                    name: "client-a",
                    path: "/work/client-a",
                    totalTokens: 40,
                    totalCostUSD: 0.04,
                    daily: [
                        CostUsageDailyReport.Entry(
                            date: "2026-04-02",
                            inputTokens: 30,
                            outputTokens: 10,
                            totalTokens: 40,
                            costUSD: 0.04,
                            modelsUsed: ["gpt-5.4"],
                            modelBreakdowns: nil),
                    ],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 0.04,
                            totalTokens: 40),
                    ],
                    sources: [
                        CostUsageProjectSourceBreakdown(
                            name: "client-a",
                            path: "/work/client-a",
                            totalTokens: 40,
                            totalCostUSD: 0.04,
                            daily: [
                                CostUsageDailyReport.Entry(
                                    date: "2026-04-02",
                                    inputTokens: 30,
                                    outputTokens: 10,
                                    totalTokens: 40,
                                    costUSD: 0.04,
                                    modelsUsed: ["gpt-5.4"],
                                    modelBreakdowns: nil),
                            ],
                            modelBreakdowns: nil),
                    ]),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let payload = CodexBarCLI.makeCostPayload(provider: .codex, snapshot: snapshot, error: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode cost payload JSON")
            return
        }

        #expect(json.contains("\"projects\""))
        #expect(json.contains("\"sources\""))
        #expect(json.contains("\"name\":\"client-a\""))
        #expect(json.contains("/work/client-a") || json.contains("\\/work\\/client-a"))
        #expect(json.contains("\"totalCost\":0.04"))
        #expect(json.contains("\"daily\""))
        #expect(json.contains("\"gpt-5.4\""))
    }

    @Test
    func `encodes exact codex model I ds and zero cost breakdowns`() throws {
        let payload = CostPayload(
            provider: "codex",
            source: "local",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionTokens: 155,
            sessionCostUSD: 0,
            historyDays: 30,
            last30DaysTokens: 155,
            last30DaysCostUSD: 0,
            daily: [
                CostDailyEntryPayload(
                    date: "2025-12-21",
                    inputTokens: 120,
                    outputTokens: 15,
                    cacheReadTokens: 20,
                    cacheCreationTokens: nil,
                    totalTokens: 155,
                    costUSD: 0,
                    modelsUsed: ["gpt-5.3-codex-spark", "gpt-5.2-codex"],
                    modelBreakdowns: [
                        CostModelBreakdownPayload(modelName: "gpt-5.3-codex-spark", costUSD: 0, totalTokens: 15),
                        CostModelBreakdownPayload(modelName: "gpt-5.2-codex", costUSD: 1.23, totalTokens: 140),
                    ]),
            ],
            totals: CostTotalsPayload(
                totalInputTokens: 120,
                totalOutputTokens: 15,
                cacheReadTokens: 20,
                cacheCreationTokens: nil,
                totalTokens: 155,
                totalCostUSD: 0),
            error: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode cost payload JSON")
            return
        }

        #expect(json.contains("\"gpt-5.3-codex-spark\""))
        #expect(json.contains("\"gpt-5.2-codex\""))
        #expect(!json.contains("\"gpt-5.2\""))
        #expect(json.contains("\"cost\":0"))
        #expect(json.contains("\"totalTokens\":140"))
    }

    @Test
    func `cost estimate hint is stable string`() {
        let hint = UsageFormatter.costEstimateHint
        #expect(!hint.isEmpty)
        #expect(hint.contains("Estimated"))
        #expect(UsageFormatter.costEstimateHint(provider: .claude).contains("cache read/write tokens"))
    }

    @Test
    func `cursor cookie source off produces a failed JSON payload`() throws {
        let settings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .off,
            manualCookieHeader: nil)
        let error = try #require(CodexBarCLI.cursorCostAvailabilityError(.cursor, settings: settings))
        let payload = CodexBarCLI.makeCostPayload(provider: .cursor, snapshot: nil, error: error)
        let json = try #require(CodexBarCLI.encodeJSON([payload], pretty: false))

        #expect(CodexBarCLI.mapError(error) == .failure)
        #expect(json.contains("\"provider\":\"cursor\""))
        #expect(json.contains("\"code\":1"))
        #expect(json.contains("cookie source is set to Off"))
        #expect(CodexBarCLI.cursorCostAvailabilityError(.cursor, settings: nil) == nil)
        #expect(CodexBarCLI.cursorCostAvailabilityError(.codex, settings: settings) == nil)
    }

    @Test
    func `cursor manual cookie source rejects an empty header`() throws {
        let settings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "  ")
        let error = try #require(CodexBarCLI.cursorCostAvailabilityError(.cursor, settings: settings))

        #expect(CodexBarCLI.mapError(error) == .failure)
        #expect(error.localizedDescription.contains("non-empty Manual cookie header"))
        #expect(CodexBarCLI.cursorCostHeaderOverride(.cursor, settings: settings) == nil)
    }

    @Test
    func `cursor settings resolution errors fail closed`() throws {
        let resolutionError = CursorCostSettingsTestError()
        let error = try #require(CodexBarCLI.cursorCostAvailabilityError(
            .cursor,
            settings: nil,
            resolutionError: resolutionError))

        #expect(error.localizedDescription == resolutionError.localizedDescription)
        #expect(CodexBarCLI.cursorCostAvailabilityError(
            .codex,
            settings: nil,
            resolutionError: resolutionError) == nil)
    }

    @Test
    func `openCodex JSON payload stays on a separate source and omits invented projects`() {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 12,
            last30DaysCostUSD: 1.5,
            currencyCode: "USD",
            historyDays: 7,
            costProvenance: .listPriceEstimate,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-16",
                    inputTokens: 10,
                    outputTokens: 2,
                    reasoningTokens: 3,
                    totalTokens: 12,
                    costUSD: 1.5,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: nil,
                    estimatedRequestCount: 1),
            ],
            updatedAt: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let payload = CodexBarCLI.makeOpenCodexCostPayload(snapshot: snapshot, calendar: calendar)
        #expect(payload.provider == "opencodex")
        #expect(payload.source == "opencodex")
        #expect(payload.projects.isEmpty)
        #expect(payload.daily.first?.reasoningTokens == 3)
        #expect(payload.provenance == CostProvenance.listPriceEstimate.rawValue)
        #expect(payload.coverage?.estimated == 1)
    }
}

private func sessionTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "MMM d, HH:mm"
    return formatter.string(from: date)
}

private struct CursorCostSettingsTestError: LocalizedError {
    var errorDescription: String? {
        "Cursor settings resolution failed."
    }
}
