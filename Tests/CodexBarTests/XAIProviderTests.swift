import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct XAIProviderTests {
    @Test
    func `settings reader trims whitespace and quotes`() {
        #expect(XAISettingsReader.apiKey(environment: [
            XAISettingsReader.apiKeyEnvironmentKey: "  'fixture-management-key'  ",
        ]) == "fixture-management-key")
        #expect(XAISettingsReader.apiKey(environment: [:]) == nil)
        #expect(XAISettingsReader.teamID(environment: [
            XAISettingsReader.teamIDEnvironmentKey: " \"team-1234\" ",
        ]) == "team-1234")
        #expect(XAISettingsReader.teamID(environment: [:]) == nil)
    }

    @Test
    func `descriptor preflight preserves team ID validation errors`() async throws {
        let missing = Self.context(environment: [
            XAISettingsReader.apiKeyEnvironmentKey: "fixture-management-key",
        ])
        let invalid = Self.context(environment: [
            XAISettingsReader.apiKeyEnvironmentKey: "fixture-management-key",
            XAISettingsReader.teamIDEnvironmentKey: "team/../other",
        ])
        let strategy = try #require(await XAIProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(missing).first)

        for (context, expected) in [(missing, XAISettingsError.missingTeamID), (invalid, .invalidTeamID)] {
            do {
                _ = try await strategy.fetch(context)
                Issue.record("Expected xAI team ID validation error")
            } catch let error as XAISettingsError {
                #expect(error == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `balance preview and usage requests retain posted credit`(engine: ProviderPluginEngineKind) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.scheme == "https")
            #expect(url.host == "management-api.x.ai")
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(url.query == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-management-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            switch url.path {
            case "/v1/billing/teams/team-1234/prepaid/balance":
                #expect(request.httpMethod == "GET")
                return Self.response(url: url, body: Self.balanceFixture)
            case "/v1/billing/teams/team-1234/postpaid/invoice/preview":
                #expect(request.httpMethod == "GET")
                return Self.response(
                    url: url,
                    body: #"{"billingCycle":{"year":2027,"month":1},"effectiveSpendingLimit":"50000","#
                        + #""coreInvoice":{"amountAfterVat":"350","totalWithCorr":{"val":"350"}}}"#)
            case "/v1/billing/teams/team-1234/usage":
                #expect(request.httpMethod == "POST")
                let body = try #require(request.httpBody)
                let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                let analytics = try #require(payload["analyticsRequest"] as? [String: Any])
                let timeRange = try #require(analytics["timeRange"] as? [String: Any])
                #expect(timeRange["startTime"] as? String == "2026-12-17 00:00:00")
                #expect(timeRange["endTime"] as? String == "2027-01-15 08:00:00")
                #expect(timeRange["timezone"] as? String == "Etc/GMT")
                #expect(analytics["timeUnit"] as? String == "TIME_UNIT_DAY")
                let values = try #require(analytics["values"] as? [[String: String]])
                #expect(values.map { $0["name"] } == ["usd", "units", "transactions"])
                #expect(values.allSatisfy { $0["aggregation"] == "AGGREGATION_SUM" })
                #expect(analytics["groupBy"] as? [String] == ["description", "unit_type"])
                return Self.response(url: url, body: Self.usageFixture)
            default:
                Issue.record("Unexpected request path: \(url.path)")
                throw URLError(.badURL)
            }
        }

        let snapshot = try await Self.runtime(transport: transport, engine: engine).fetchUsage(
            settings: ["XAI_TEAM_ID": "team-1234"],
            secrets: ["XAI_MANAGEMENT_API_KEY": "fixture-management-key"],
            now: now)

        #expect(await transport.requests().compactMap { $0.url?.lastPathComponent } == ["balance", "preview", "usage"])
        #expect(snapshot.providerCost?.used == 10)
        #expect(snapshot.details.first?.rows.prefix(2).map(\.label) == ["Prepaid balance", "Live remaining (est.)"])
        #expect(snapshot.detailRow(label: "Live remaining (est.)")?.value == "$6.50")
        #expect(snapshot.detailRow(label: "Current cycle")?.value == "$3.50")
        #expect(snapshot.detailRow(label: "Current cycle")?.secondaryValue == "2027-01")
        #expect(snapshot.detailRow(label: "Spending limit")?.value == "$500.00")
        #expect(snapshot.detailRow(label: "Last 30 days")?.value == "$2.01")
        #expect(snapshot.details.first?.chart == nil)
        #expect(snapshot.dataConfidence == .exact)

        let costUsage = try #require(snapshot.costUsage)
        #expect(costUsage.updatedAt == now)
        #expect(costUsage.historyCoverageIsEstablished == true)
        #expect(costUsage.historyScanIsPartial == false)
        #expect(costUsage.sessionTokens == 850)
        #expect(costUsage.sessionCostUSD == 0.25)
        #expect(costUsage.sessionRequests == 1)
        #expect(costUsage.last30DaysTokens == 4050)
        #expect(costUsage.last30DaysRequests == 9)
        #expect(abs((costUsage.last30DaysCostUSD ?? 0) - 2.00973725) < 1e-9)
        #expect(costUsage.daily.map(\.date) == ["2027-01-13", "2027-01-14", "2027-01-15"])

        let dayOne = try #require(costUsage.daily.first)
        #expect(dayOne.inputTokens == 1000)
        #expect(dayOne.cacheReadTokens == 500)
        #expect(dayOne.outputTokens == 500)
        #expect(dayOne.reasoningTokens == 200)
        #expect(dayOne.totalTokens == 2000)
        #expect(dayOne.requestCount == 6)
        let grokBreakdown = try #require(dayOne.modelBreakdowns?.first { $0.modelName == "grok-4.7" })
        #expect(grokBreakdown.inputTokens == 1000)
        #expect(grokBreakdown.cacheReadTokens == 500)
        #expect(grokBreakdown.outputTokens == 500)
        #expect(grokBreakdown.reasoningTokens == 200)
        #expect(grokBreakdown.totalTokens == 2000)
        #expect(grokBreakdown.requestCount == 4)
        let ttsBreakdown = try #require(dayOne.modelBreakdowns?.first { $0.modelName == "Text-to-Speech" })
        #expect(ttsBreakdown.totalTokens == 0)
        #expect(ttsBreakdown.requestCount == 2)
        #expect(ttsBreakdown.costUSD == 0.5)
        #expect(XAICostUsageMapping.tokenSnapshot(from: snapshot, historyDays: 30) == costUsage)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `preview omits zero spending limit and handles non-token fractional units`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usageBody = #"""
        {
          "timeSeries": [
            {
              "group": ["API grok-4.7", "Completion text tokens"],
              "dataPoints": [{"timestamp":"2027-01-15T00:00:00Z","values":[0.12, 300, 3]}]
            },
            {
              "group": ["API grok-4.7", "Reasoning text tokens"],
              "dataPoints": [{"timestamp":"2027-01-15T00:00:00Z","values":[0.08, 200, 5]}]
            },
            {
              "group": ["API Speech-to-Text", "Input audio seconds"],
              "dataPoints": [{"timestamp":"2027-01-15T00:00:00Z","values":[0.05, 12.5, 2]}]
            }
          ],
          "limitReached": false
        }
        """#
        let previewBody = #"{"effectiveSpendingLimit":"0","#
            + #""coreInvoice":{"amountAfterVat":"0","totalWithCorr":{"val":"25"}}}"#
        let snapshot = try await Self.fetch(
            previewBody: previewBody,
            usageBody: usageBody,
            engine: engine)
        #expect(snapshot.detailRow(label: "Current cycle")?.value == "$0.25")
        #expect(snapshot.detailRow(label: "Current cycle")?.secondaryValue == nil)
        #expect(snapshot.detailRow(label: "Spending limit") == nil)

        let costUsage = try #require(snapshot.costUsage)
        #expect(costUsage.sessionTokens == 500)
        #expect(costUsage.sessionRequests == 7)
        let day = try #require(costUsage.daily.first)
        let grok = try #require(day.modelBreakdowns?.first { $0.modelName == "grok-4.7" })
        #expect(grok.requestCount == 5)
        #expect(grok.outputTokens == 500)
        #expect(grok.reasoningTokens == 200)
        let stt = try #require(day.modelBreakdowns?.first { $0.modelName == "Speech-to-Text" })
        #expect(stt.totalTokens == 0)
        #expect(stt.requestCount == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `deduplicated token requests retain larger cached and completion counts`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usageBody = #"""
        {
          "timeSeries": [
            {
              "group": ["API grok-4.7", "Prompt text tokens"],
              "dataPoints": [{"timestamp":"2027-01-15T00:00:00Z","values":[0.10, 200, 1]}]
            },
            {
              "group": ["API grok-4.7", "Cached prompt text tokens"],
              "dataPoints": [{"timestamp":"2027-01-15T00:00:00Z","values":[0.02, 400, 2]}]
            },
            {
              "group": ["API grok-4.7", "Completion text tokens"],
              "dataPoints": [{"timestamp":"2027-01-15T00:00:00Z","values":[0.08, 150, 2]}]
            }
          ],
          "limitReached": false
        }
        """#
        let snapshot = try await Self.fetch(usageBody: usageBody, engine: engine)
        let costUsage = try #require(snapshot.costUsage)
        #expect(costUsage.sessionRequests == 2)
        #expect(costUsage.last30DaysRequests == 2)
        let day = try #require(costUsage.daily.first)
        #expect(day.requestCount == 2)
        let grok = try #require(day.modelBreakdowns?.first { $0.modelName == "grok-4.7" })
        #expect(grok.requestCount == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines, [
        ("13364", "$141.17"),
        ("0", "$274.81"),
        ("-100", "$275.81"),
        ("30000", "$-25.19"),
    ])
    func `live estimate subtracts documented invoice cents without replacing posted balance`(
        engine: ProviderPluginEngineKind, invoice: (String, String)) async throws
    {
        let snapshot = try await Self.fetch(
            balanceBody: #"{"total":{"val":"-27481"}}"#,
            previewBody: #"{"coreInvoice":{"amountAfterVat":"\#(invoice.0)","totalWithCorr":{"val":"999"}}}"#,
            engine: engine)
        #expect(snapshot.providerCost?.used == 274.81)
        #expect(snapshot.detailRow(label: "Prepaid balance")?.value == "$274.81")
        #expect(snapshot.detailRow(label: "Live remaining (est.)")?.value == invoice.1)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines, [
        ("-4104", "0", "-7", "$40.97"),
        ("-4104", "0", "0", "$41.04"),
        ("-1000", "500", "-1000", "$-5.00"),
        ("-1000", "0", "100", "$11.00"),
    ])
    func `live estimate subtracts prepaid credits used alongside invoice due`(
        engine: ProviderPluginEngineKind,
        fixture: (String, String, String, String)) async throws
    {
        let previewBody = #"{"coreInvoice":{"amountAfterVat":"\#(fixture.1)","#
            + #""prepaidCreditsUsed":{"val":"\#(fixture.2)"}}}"#
        let snapshot = try await Self.fetch(
            balanceBody: #"{"total":{"val":"\#(fixture.0)"}}"#,
            previewBody: previewBody,
            engine: engine)
        #expect(snapshot.detailRow(label: "Live remaining (est.)")?.value == fixture.3)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines, [
        (403, #"{"coreInvoice":{"amountAfterVat":"350"}}"#),
        (404, #"{"coreInvoice":{"amountAfterVat":"350"}}"#),
        (200, ""),
        (200, #"{}"#),
        (200, #"{"coreInvoice":{"amountAfterVat":null}}"#),
        (200, #"{"coreInvoice":{"amountAfterVat":""}}"#),
        (200, #"{"coreInvoice":{"amountAfterVat":"n/a"}}"#),
        (200, #"{"coreInvoice":{"amountAfterVat":"9007199254740993"}}"#),
        (200, #"{"coreInvoice":{"amountAfterVat":"0","prepaidCreditsUsed":{"val":"n/a"}}}"#),
        (200, #"{"coreInvoice":{"amountAfterVat":"0","prepaidCreditsUsed":{}}}"#),
        (200, #"{"coreInvoice":{"amountAfterVat":"0","prepaidCreditsUsed":{"val":"9007199254740993"}}}"#),
    ])
    func `unavailable invoice preview omits only the estimate`(
        engine: ProviderPluginEngineKind, response: (Int, String)) async throws
    {
        let snapshot = try await Self.fetch(previewBody: response.1, previewStatus: response.0, engine: engine)
        #expect(snapshot.providerCost?.used == 10)
        #expect(snapshot.detailRow(label: "Live remaining (est.)") == nil)
        #expect(snapshot.costUsage?.daily.count == 3)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invoice preview transport failure preserves posted credit and history`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/preview") { throw URLError(.timedOut) }
            return Self.response(
                url: url,
                body: url.path.hasSuffix("/balance")
                    ? Self.balanceFixture : Self.usageFixture)
        }
        let snapshot = try await Self.runtime(transport: transport, engine: engine).fetchUsage(
            settings: ["XAI_TEAM_ID": "team-1234"],
            secrets: ["XAI_MANAGEMENT_API_KEY": "fixture-management-key"],
            now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(snapshot.providerCost?.used == 10)
        #expect(snapshot.detailRow(label: "Live remaining (est.)") == nil)
        #expect(snapshot.costUsage?.daily.count == 3)
    }

    @Test(arguments: [
        (#"{"total":{"val":"2500"}}"#, -25.0),
        (#"{"total":{"val":"0"}}"#, 0.0),
        (#"{"total":{"val":"-333"}}"#, 3.33),
    ])
    func `ledger balances match the production goldens`(body: String, expected: Double) async throws {
        let snapshot = try await Self.fetch(balanceBody: body)
        #expect(snapshot.providerCost?.used == expected)
    }

    @Test
    func `malformed balance is a classified parse failure`() async throws {
        do {
            _ = try await Self.fetch(balanceBody: #"{"total":{"val":"n/a"}}"#)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(error.message.contains("balance total.val"))
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .authenticationExpired),
        (404, .apiFailure),
        (429, .rateLimited),
        (503, .apiFailure),
    ])
    func `balance errors retain classified surfaces`(
        status: Int,
        kind: ProviderFetchClassifiedError.Kind) async throws
    {
        do {
            _ = try await Self.fetch(balanceStatus: status)
            Issue.record("Expected classified xAI failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        }
    }

    @Test
    func `history failure preserves balance and partial history lowers confidence`() async throws {
        let degraded = try await Self.fetch(usageStatus: 500)
        #expect(degraded.providerCost?.used == 10)
        #expect(degraded.costUsage == nil)
        #expect(degraded.details.first?.chart == nil)
        #expect(degraded.dataConfidence == .exact)
        #expect(XAICostUsageMapping.isAnalyticsUnavailable(degraded))
        #expect(XAICostUsageMapping.tokenSnapshot(from: degraded, historyDays: 30) == nil)

        let partial = try await Self.fetch(usageBody: Self.usageFixture.replacingOccurrences(
            of: #""limitReached": false"#,
            with: #""limitReached": true"#))
        #expect(partial.detailRow(label: "Last 30 days (partial)")?.value == "$2.01")
        #expect(partial.dataConfidence == .estimated)
        #expect(partial.costUsage?.historyCoverageIsEstablished == false)
        #expect(partial.costUsage?.historyScanIsPartial == true)
        #expect(partial.costUsage?.historyLabel == "Last 30 days (partial)")
    }

    @Test
    func `successful empty usage history emits empty costUsage`() async throws {
        let snapshot = try await Self.fetch(usageBody: #"{"timeSeries":[],"limitReached":false}"#)
        #expect(snapshot.costUsage?.daily.isEmpty == true)
        #expect(snapshot.details.first?.chart == nil)
        #expect(XAICostUsageMapping.isAnalyticsUnavailable(snapshot) == false)
        let mapped = try #require(XAICostUsageMapping.tokenSnapshot(from: snapshot, historyDays: 365))
        #expect(mapped.daily.isEmpty)
        #expect(mapped.last30DaysCostUSD == 0)
        #expect(mapped.last30DaysTokens == 0)
        #expect(mapped.last30DaysRequests == 0)
        #expect(mapped.sessionCostUSD == nil)
        #expect(mapped.historyDays == 30)
    }

    @Test(arguments: BundledPluginTestSupport.engines) @MainActor
    func `explicitly reported zero-usage days retain current-day zero metrics`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usageBody = #"""
        {
          "timeSeries": [
            {
              "group": ["API grok-4.7", "Prompt text tokens"],
              "dataPoints": [
                {"timestamp":"2027-01-13T00:00:00Z","values":[0.4, 1000, 4]},
                {"timestamp":"2027-01-14T00:00:00Z","values":[0, 0, 0]},
                {"timestamp":"2027-01-15T00:00:00Z","values":[0, 0, 0]}
              ]
            },
            {
              "group": ["API Text-to-Speech", "Input characters"],
              "dataPoints": [
                {"timestamp":"2027-01-15T00:00:00Z","values":[0, 0, 0]}
              ]
            }
          ],
          "limitReached": false
        }
        """#
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try await Self.fetch(usageBody: usageBody, engine: engine)
        let costUsage = try #require(snapshot.costUsage)
        #expect(costUsage.sessionCostUSD == 0)
        #expect(costUsage.sessionTokens == 0)
        #expect(costUsage.sessionRequests == 0)
        #expect(costUsage.last30DaysCostUSD == 0.4)
        #expect(costUsage.last30DaysTokens == 1000)
        #expect(costUsage.last30DaysRequests == 4)
        #expect(costUsage.daily.map(\.date) == ["2027-01-13", "2027-01-14", "2027-01-15"])

        let zeroPastDay = try #require(costUsage.daily.first { $0.date == "2027-01-14" })
        #expect(zeroPastDay.costUSD == 0)
        #expect(zeroPastDay.totalTokens == 0)
        #expect(zeroPastDay.requestCount == 0)
        #expect(zeroPastDay.modelBreakdowns == nil)

        let zeroToday = try #require(costUsage.daily.first { $0.date == "2027-01-15" })
        #expect(zeroToday.costUSD == 0)
        #expect(zeroToday.totalTokens == 0)
        #expect(zeroToday.requestCount == 0)
        #expect(zeroToday.modelBreakdowns == nil)

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .xai)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .xai,
            metadata: descriptor.metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.kpis.contains { $0.title == "Today" && $0.value == "$0.00" })
    }

    @Test(arguments: [
        #"{}"#,
        #"{"timeSeries":null,"limitReached":false}"#,
        #"{"timeSeries":[{}],"limitReached":false}"#,
        #"{"timeSeries":[{"group":["API grok-4.7"],"dataPoints":[]}],"limitReached":false}"#,
        #"{"timeSeries":[{"group":["API grok-4.7","Prompt text tokens"],"#
            + #""dataPoints":[{"timestamp":"2027-01-15T00:00:00Z","values":[0.1]}]}],"limitReached":false}"#,
        #"{"timeSeries":[{"group":["API grok-4.7","Prompt text tokens"],"#
            + #""dataPoints":[{"timestamp":"2027-01-15T00:00:00Z","values":[0.1, 1.5, 1]}]}],"limitReached":false}"#,
        #"{"timeSeries":[{"group":["API grok-4.7","Prompt text tokens"],"#
            + #""dataPoints":[{"timestamp":"2027-01-15T00:00:00Z","values":[0.1, 10, -1]}]}],"limitReached":false}"#,
    ])
    func `malformed successful usage history stays unavailable`(body: String) async throws {
        let snapshot = try await Self.fetch(usageBody: body)
        #expect(snapshot.costUsage == nil)
        #expect(snapshot.details.first?.chart == nil)
        #expect(XAICostUsageMapping.isAnalyticsUnavailable(snapshot))
        #expect(XAICostUsageMapping.tokenSnapshot(from: snapshot, historyDays: 30) == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func `descriptor registry menu card and CLI retain xAI presentation`(hasPreview: Bool) async throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .xai)
        #expect(descriptor.metadata.displayName == "xAI")
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(try #require(ProviderCatalog.implementation(for: .xai)) is PluginAPIKeyProviderImplementation)

        let previewFixture = #"{"billingCycle":{"year":2027,"month":1},"#
            + #""coreInvoice":{"amountAfterVat":"350","totalWithCorr":{"val":"350"}}}"#
        let snapshot = try await Self.fetch(previewBody: hasPreview ? previewFixture : "{}")
        let model = UsageMenuCardView.Model.make(.init(
            provider: .xai,
            metadata: descriptor.metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(model.providerCost?.spendLine == "Balance: $10.00")
        #expect(model.providerDetails.flatMap(\.rows).contains { $0.label == "Live remaining (est.)" } == hasPreview)
        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.kpis.contains { $0.title == "Today" && $0.value == "$0.25" })
        #expect(dashboard.kpis.contains { $0.title == "30d cost" && $0.value == "$2.01" })
        #expect(dashboard.kpis.contains { $0.title == "30d tokens" })
        #expect(dashboard.kpis.contains { $0.title == "Requests" && $0.value == "9" })
        #expect(dashboard.detailLines.contains { $0.contains("grok-4.7") })

        let text = CLIRenderer.renderText(
            provider: .xai,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "xAI (api)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))
        #expect(text.contains("Prepaid balance: $10.00"))
        #expect(text.contains("Live remaining (est.): $6.50") == hasPreview)
        #expect(text.contains("Plan: Management API"))
    }

    @Test @MainActor
    func `submenu-only cost summary mode retains xAI tokenUsage history`() async throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .xai)
        #expect(descriptor.tokenCost.showsCostMenuSection == true)

        let snapshot = try await Self.fetch()
        let tokenSnapshot = try #require(XAICostUsageMapping.tokenSnapshot(from: snapshot, historyDays: 30))
        let model = UsageMenuCardView.Model.make(.init(
            provider: .xai,
            metadata: descriptor.metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            costSummaryInlineEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(model.inlineUsageDashboard == nil)
        #expect(model.tokenUsage != nil)
    }

    @Test @MainActor
    func `primary cost history preserves prefiltered reporting period when snapshot is present`() async throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .xai)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try await Self.fetch()
        let mtdTokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 850,
            sessionCostUSD: 0.25,
            sessionRequests: 1,
            last30DaysTokens: 850,
            last30DaysCostUSD: 0.25,
            last30DaysRequests: 1,
            historyDays: 15,
            historyCoverageIsEstablished: true,
            historyLabel: "Month to date",
            costProvenance: .vendorMetered,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2027-01-15",
                    inputTokens: 600,
                    outputTokens: 250,
                    cacheReadTokens: 0,
                    totalTokens: 850,
                    requestCount: 1,
                    costUSD: 0.25,
                    modelsUsed: ["grok-4.7"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "grok-4.7",
                            costUSD: 0.25,
                            totalTokens: 850,
                            requestCount: 1),
                    ]),
            ],
            updatedAt: now)

        let resolved = descriptor.presentation.menuCard.primaryCostHistory(
            snapshot: snapshot,
            tokenSnapshot: mtdTokenSnapshot)
        #expect(resolved == mtdTokenSnapshot)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .xai,
            metadata: descriptor.metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: mtdTokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.kpis.contains { $0.title == "Requests" && $0.value == "1" })
        #expect(dashboard.kpis.contains { $0.value == "$0.25" })
        #expect(dashboard.kpis.contains { $0.value == "$2.01" } == false)
    }

    @Test @MainActor
    func `descriptor registry menu card proof capture`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_XAI_PROOF_DIR"] else { return }
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .xai)
        for hasPreview in [false, true] {
            let previewFixture = #"{"billingCycle":{"year":2027,"month":1},"#
                + #""coreInvoice":{"amountAfterVat":"350","totalWithCorr":{"val":"350"}}}"#
            let snapshot = try await Self.fetch(previewBody: hasPreview ? previewFixture : "{}")
            let model = UsageMenuCardView.Model.make(.init(
                provider: .xai,
                metadata: descriptor.metadata,
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: true,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                costSummaryInlineEnabled: true,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: Date(timeIntervalSince1970: 1_800_000_000)))
            let hosting = NSHostingView(rootView: UsageMenuCardView(model: model, width: 360)
                .padding(16)
                .frame(width: 392)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(.light))
            hosting.appearance = NSAppearance(named: .aqua)
            let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent(hasPreview ? "xai-after.png" : "xai-before.png"))
        }
    }

    @Test
    func `config API key and team ID project into the fetch environment`() {
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                XAISettingsReader.apiKeyEnvironmentKey: "environment-key",
                XAISettingsReader.teamIDEnvironmentKey: "environment-team",
            ],
            provider: .xai,
            config: ProviderConfig(id: .xai, apiKey: "config-key", workspaceID: "config-team"))

        #expect(XAISettingsReader.apiKey(environment: environment) == "config-key")
        #expect(XAISettingsReader.teamID(environment: environment) == "config-team")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .xai))
    }

    private static func fetch(
        balanceBody: String = balanceFixture,
        balanceStatus: Int = 200,
        previewBody: String = "{}",
        previewStatus: Int = 200,
        usageBody: String = usageFixture,
        usageStatus: Int = 200,
        engine: ProviderPluginEngineKind = .quickJS) async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/prepaid/balance") {
                return Self.response(url: url, body: balanceBody, statusCode: balanceStatus)
            }
            if url.path.hasSuffix("/postpaid/invoice/preview") {
                return Self.response(url: url, body: previewBody, statusCode: previewStatus)
            }
            return Self.response(url: url, body: usageBody, statusCode: usageStatus)
        }
        return try await Self.runtime(transport: transport, engine: engine).fetchUsage(
            settings: ["XAI_TEAM_ID": "team-1234"],
            secrets: ["XAI_MANAGEMENT_API_KEY": "fixture-management-key"],
            now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private static func runtime(
        transport: any ProviderHTTPTransport,
        engine: ProviderPluginEngineKind = .quickJS) throws -> ProviderPluginRuntime
    {
        try BundledPluginTestSupport.runtime("xai", engine: engine, transport: transport)
    }

    private static func context(environment: [String: String]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: XAITestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func response(url: URL, body: String, statusCode: Int = 200) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]) ?? HTTPURLResponse()
        return (Data(body.utf8), response)
    }

    static let balanceFixture = #"{"total":{"val":"-1000"}}"#

    static let usageFixture = #"""
    {
      "timeSeries": [
        {
          "group": ["API grok-4.7", "Prompt text tokens"],
          "dataPoints": [
            {"timestamp":"2027-01-13T00:00:00Z","values":[0.4, 1000, 4]},
            {"timestamp":"2027-01-14T00:00:00Z","values":[0.3, 800, 2]},
            {"timestamp":"2027-01-15T00:00:00Z","values":[0.15, 600, 1]}
          ]
        },
        {
          "group": ["API grok-4.7", "Cached prompt text tokens"],
          "dataPoints": [
            {"timestamp":"2027-01-13T00:00:00Z","values":[0.05, 500, 4]},
            {"timestamp":"2027-01-14T00:00:00Z","values":[0, 0, 0]},
            {"timestamp":"2027-01-15T00:00:00Z","values":[0, 0, 0]}
          ]
        },
        {
          "group": ["API grok-4.7", "Completion text tokens"],
          "dataPoints": [
            {"timestamp":"2027-01-13T00:00:00Z","values":[0.25, 300, 4]},
            {"timestamp":"2027-01-14T00:00:00Z","values":[0.2, 400, 2]},
            {"timestamp":"2027-01-15T00:00:00Z","values":[0.1, 250, 1]}
          ]
        },
        {
          "group": ["API grok-4.7", "Reasoning text tokens"],
          "dataPoints": [
            {"timestamp":"2027-01-13T00:00:00Z","values":[0.05973725, 200, 3]}
          ]
        },
        {
          "group": ["API Text-to-Speech", "Input characters"],
          "dataPoints": [
            {"timestamp":"2027-01-13T00:00:00Z","values":[0.5, 12000, 2]},
            {"timestamp":"2027-01-14T00:00:00Z","values":[0, 0, 0]}
          ]
        }
      ],
      "limitReached": false
    }
    """#
}

private struct XAITestClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        "unused"
    }

    func detectVersion() -> String? {
        nil
    }
}
