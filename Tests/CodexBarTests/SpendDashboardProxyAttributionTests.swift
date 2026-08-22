import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardProxyAttributionTests {
    @Test
    func `missing proxy configuration clears the saved presentation`() {
        let presentation = spendDashboardCLIProxyAPIConfigurationPresentation(
            loadResult: .missing,
            currentBaseURL: "http://localhost:8317",
            hasSavedConfiguration: true)

        #expect(presentation.baseURL == "http://localhost:8317")
        #expect(!presentation.hasSavedConfiguration)
    }

    @Test
    func `invalid proxy configuration clears the saved presentation`() {
        let presentation = spendDashboardCLIProxyAPIConfigurationPresentation(
            loadResult: .invalid,
            currentBaseURL: "http://localhost:8317",
            hasSavedConfiguration: true)

        #expect(presentation.baseURL == "http://localhost:8317")
        #expect(!presentation.hasSavedConfiguration)
    }

    @Test
    func `temporarily unavailable proxy configuration preserves the presentation`() {
        let presentation = spendDashboardCLIProxyAPIConfigurationPresentation(
            loadResult: .temporarilyUnavailable,
            currentBaseURL: "http://localhost:8317",
            hasSavedConfiguration: true)

        #expect(presentation.baseURL == "http://localhost:8317")
        #expect(presentation.hasSavedConfiguration)
    }

    @Test
    func `found proxy configuration refreshes the presentation`() {
        let presentation = spendDashboardCLIProxyAPIConfigurationPresentation(
            loadResult: .found(CLIProxyAPIConnectionSettings(
                baseURL: "http://127.0.0.1:8317",
                managementKey: "test-key")),
            currentBaseURL: CLIProxyAPIConnectionSettings.defaultBaseURL,
            hasSavedConfiguration: false)

        #expect(presentation.baseURL == "http://127.0.0.1:8317")
        #expect(presentation.hasSavedConfiguration)
    }

    @Test
    func `unresolved route describes known facts without an unknown warning`() {
        let attribution = CostUsageAttribution(
            client: .claudeCode,
            route: .unknown,
            modelProvider: .openAI,
            evidence: [.modelProvider])

        #expect(spendDashboardModelSourceText(
            providerName: "Claude",
            attribution: attribution) == "Claude · OpenAI model via Claude Code")
    }

    @Test
    func `confirmed proxy route without upstream telemetry does not infer a backend`() {
        let attribution = CostUsageAttribution(
            client: .claudeCode,
            route: .cliProxyAPI,
            modelProvider: .openAI,
            evidence: [.cliProxyRequestLog, .modelProvider])

        #expect(spendDashboardModelSourceText(
            providerName: "Claude",
            attribution: attribution) == "CLIProxyAPI via Claude Code")
    }

    @Test
    func `proxy attribution survives dashboard aggregation and describes the route`() throws {
        let attribution = CostUsageAttribution(
            client: .claudeCode,
            route: .cliProxyAPI,
            modelProvider: .openAI,
            upstream: .init(provider: "codex", authType: .oauth),
            evidence: [.cliProxyRequestLog, .cliProxyUsageTelemetry, .modelProvider])
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: 90,
            outputTokens: 10,
            totalTokens: 100,
            costUSD: 1,
            modelsUsed: ["gpt-5.5"],
            modelBreakdowns: [
                .init(
                    modelName: "gpt-5.5",
                    costUSD: 1,
                    totalTokens: 100,
                    attribution: attribution),
            ])
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 1,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1,
            daily: [entry],
            updatedAt: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let model = SpendDashboardModel.build(
            inputs: [
                .init(
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: snapshot),
            ],
            requestedDays: 7,
            now: now,
            calendar: calendar)

        let row = try #require(model.groups.first?.models.first)
        #expect(row.provider == .codex)
        #expect(row.attribution == attribution)
        #expect(spendDashboardModelSourceText(
            providerName: row.providerName,
            attribution: row.attribution) == "Codex OAuth · CLIProxyAPI via Claude Code")
    }

    @Test
    func `model row identity includes complete proxy attribution`() throws {
        let inventoryAttribution = CostUsageAttribution(
            client: .claudeCode,
            route: .cliProxyAPI,
            modelProvider: .openAI,
            upstream: .init(
                provider: "codex",
                authType: .oauth,
                model: "gpt-5.5"),
            evidence: [.cliProxyAuthInventory, .cliProxyRequestLog, .modelProvider])
        let telemetryAttribution = CostUsageAttribution(
            client: .claudeCode,
            route: .cliProxyAPI,
            modelProvider: .openAI,
            upstream: .init(
                provider: "codex",
                authType: .oauth,
                model: "openai/gpt-5.5",
                executorType: "CodexExecutor"),
            evidence: [.cliProxyRequestLog, .cliProxyUsageTelemetry, .modelProvider])
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: 100,
            outputTokens: 100,
            totalTokens: 200,
            costUSD: 2,
            modelsUsed: ["gpt-5.5"],
            modelBreakdowns: [
                .init(
                    modelName: "gpt-5.5",
                    costUSD: 1,
                    totalTokens: 100,
                    attribution: inventoryAttribution),
                .init(
                    modelName: "gpt-5.5",
                    costUSD: 1,
                    totalTokens: 100,
                    attribution: telemetryAttribution),
            ])
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 200,
            sessionCostUSD: 2,
            last30DaysTokens: 200,
            last30DaysCostUSD: 2,
            daily: [entry],
            updatedAt: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let model = SpendDashboardModel.build(
            inputs: [
                .init(
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: snapshot),
            ],
            requestedDays: 7,
            now: now,
            calendar: calendar)

        let group = try #require(model.groups.first)
        let rows = group.models
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.map(\.attribution) == [telemetryAttribution, inventoryAttribution])
        #expect(rows.map(\.rank) == [1, 2])
    }
}
