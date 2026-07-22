import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ShareStatsTests {
    private struct ProofSource {
        let id: String
        let provider: UsageProvider
        let name: String
        let model: String
        let tokens: Int
        let cost: Double
    }

    @Test
    func `builder preserves native currencies and unavailable spend`() throws {
        let subscriptionNames = try [
            "codex:one": #require(Self.subscriptionName(provider: .codex, rawName: "pro")),
            "cursor": #require(Self.subscriptionName(provider: .cursor, rawName: "Cursor Pro")),
            "claude": #require(Self.subscriptionName(provider: .claude, rawName: "Claude Max")),
        ]
        let payload = try #require(ShareStatsBuilder.make(
            model: Self.dashboard,
            subscriptionNames: subscriptionNames))

        #expect(payload.days == 30)
        #expect(payload.totalTokens == 500)
        #expect(payload.tokenSourceCount == 2)
        #expect(!payload.tokenCoverageIsComplete)
        #expect(payload.currencies == [
            ShareStatsCurrencyPayload(
                currencyCode: "GBP",
                estimatedCost: 12,
                coveredDayCount: 10,
                pricedSourceCount: 1,
                sourceCount: 1),
            ShareStatsCurrencyPayload(
                currencyCode: "USD",
                estimatedCost: 4,
                coveredDayCount: 0,
                pricedSourceCount: 1,
                sourceCount: 2),
        ])
        #expect(payload.providers.map(\.providerName) == ["Claude", "Codex", "Cursor"])
        #expect(payload.providers.map(\.subscriptionName) == ["Max", "Pro 20x", "Cursor Pro"])
        #expect(payload.providers.last?.estimatedCost == nil)
        #expect(payload.topModels.map(\.modelName).prefix(2) == ["Claude Sonnet 4", "GPT-5.4"])
        #expect(payload.dailyTokens == [ShareStatsDailyPayload(day: Self.date, totalTokens: 500)])
        #expect(payload.dailySourceCount == 2)
        #expect(!payload.dailyCoverageIsComplete)

        let text = ShareStatsFormatting.text(payload, style: .modelActivity)
        #expect(text.contains("You kept the models busy · last 30 days"))
        #expect(text.contains("at least 1 of 30 days active"))
        #expect(text.contains("Estimated token spend: ≥£12.00 · ≥$4.00 · pricing for 2 of 3 sources"))
        #expect(text.contains("Top model routes:"))
        #expect(text.contains("Claude Sonnet 4 via Claude"))
        #expect(text.contains("3 sources tracked"))
        #expect(text.contains("Aggregated locally by CodexBar · No prompts shared"))
        #expect(!text.contains("Cursor Pro"))
        #expect(!text.contains("Spend unavailable"))
    }

    @Test
    func `payload sanitizer excludes emails identifiers paths and prompts`() throws {
        let model = Self.dashboard(models: [
            "gpt-5.4",
            "person@example.com",
            "/Users/peter/private/model",
            "550e8400-e29b-41d4-a716-446655440000",
            "summarize my secret project",
            "abcdefabcdefabcdefabcdef",
            "https://intranet.example/client-model-2",
            "acme/private-model-v2",
            "acme-private-model-v2",
            "gpt-acme-private-model-v2",
        ])
        var subscriptionNames = try [
            "claude": #require(Self.subscriptionName(provider: .claude, rawName: "Claude Max")),
        ]
        if let unsafeCodexName = Self.subscriptionName(provider: .codex, rawName: "person@example.com") {
            subscriptionNames["codex:one"] = unsafeCodexName
        }
        if let unsafeCursorName = Self.subscriptionName(provider: .cursor, rawName: "/Users/peter/plan") {
            subscriptionNames["cursor"] = unsafeCursorName
        }
        let payload = try #require(ShareStatsBuilder.make(
            model: model,
            subscriptionNames: subscriptionNames))
        let text = ShareStatsFormatting.text(payload, style: .modelActivity)
        let summaryText = ShareStatsFormatting.text(payload, style: .summary)

        #expect(payload.topModels.map(\.modelName) == ["Claude Sonnet 4", "GPT-5.4"])
        #expect(payload.topModels.last?.totalTokens == 200)
        #expect(payload.topModels.last?.estimatedCost == 4)
        #expect(payload.modelRouteCount == 11)
        #expect(payload.shareableModelRouteCount == 2)
        #expect(payload.hiddenModelRouteCount == 9)
        #expect(payload.providers.map(\.subscriptionName) == ["Max", nil, nil])
        #expect(!text.contains("person@example.com"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("550e8400"))
        #expect(!text.contains("secret project"))
        #expect(!text.contains("abcdefabcdef"))
        #expect(!text.contains("intranet"))
        #expect(!text.contains("acme"))
        #expect(!summaryText.contains("person@example.com"))
        #expect(!summaryText.contains("/Users/"))
        #expect(!summaryText.contains("secret project"))
        #expect(!summaryText.contains("acme"))
    }

    @Test
    func `subscription labels require a plan tier provider contract`() {
        #expect(Self.subscriptionName(provider: .codex, rawName: "pro")?.displayName == "Pro 20x")
        #expect(Self.subscriptionName(provider: .codex, rawName: "Plus Plan")?.displayName == "Plus")
        #expect(Self.subscriptionName(provider: .cursor, rawName: "Cursor Pro")?.displayName == "Cursor Pro")
        #expect(Self.subscriptionName(provider: .gemini, rawName: "Paid")?.displayName == "Paid")
        #expect(Self.subscriptionName(provider: .copilot, rawName: "Business")?.displayName == "Business")
        #expect(Self.subscriptionName(provider: .perplexity, rawName: "Max")?.displayName == "Max")
        #expect(Self.subscriptionName(provider: .windsurf, rawName: "Teams")?.displayName == "Teams")
        #expect(Self.subscriptionName(provider: .zed, rawName: "Zed Pro")?.displayName == "Zed Pro")
        #expect(Self.subscriptionName(provider: .minimax, rawName: "MiniMax Star")?.displayName == "MiniMax Star")
        #expect(Self.subscriptionName(provider: .synthetic, rawName: "Starter")?.displayName == "Starter")
        #expect(Self.subscriptionName(provider: .openrouter, rawName: "Team") == nil)
        #expect(Self.subscriptionName(provider: .claude, rawName: "name@example.com") == nil)
        #expect(Self.subscriptionName(provider: .claude, rawName: "Alice Smith") == nil)
        #expect(Self.subscriptionName(provider: .codex, rawName: "123456789") == nil)
        #expect(Self.subscriptionName(provider: .cursor, rawName: "sk-live-example") == nil)
        #expect(Self.subscriptionName(provider: .claude, rawName: "internal.example") == nil)
        #expect(Self.subscriptionName(provider: .claude, rawName: "Max", accountOrganization: "Max") == nil)
    }

    @Test
    func `subscription label uses first plan bearing snapshot`() {
        let unidentified = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Self.date)
        let fallback = Self.snapshot(provider: .codex, rawName: "pro")

        let name = ShareStatsSubscriptionName.first(
            from: [unidentified, fallback],
            provider: .codex)
        #expect(name?.displayName == "Pro 20x")
    }

    @Test
    func `bedrock regional model identifiers map to public families`() {
        #expect(ShareStatsSanitizer.modelName("us.amazon.nova-2-lite-v1:0") == "Amazon Nova 2 Lite V1:0")
        #expect(ShareStatsSanitizer.modelName("global.anthropic.claude-sonnet-4-v1:0") == "Claude Sonnet 4 V1:0")
        #expect(ShareStatsSanitizer.modelName("anthropic/claude-sonnet-4") == "Claude Sonnet 4")
        #expect(ShareStatsSanitizer.modelName("openai/gpt-5.4-mini") == "GPT-5.4 Mini")
        #expect(ShareStatsSanitizer.modelName("moonshotai/kimi-k2.5") == "Kimi K2.5")
        #expect(ShareStatsSanitizer.modelName("Fable") == "Fable")
    }

    @Test
    func `public model families truncate private suffixes`() {
        #expect(ShareStatsSanitizer.modelName("openai/gpt-5.4-acme-secret") == "GPT-5.4")
        #expect(ShareStatsSanitizer.modelName("anthropic/claude-sonnet-4-client-x") == "Claude Sonnet 4")
        #expect(ShareStatsSanitizer.modelName("z-ai/glm-4.5-orgslug") == "GLM 4.5")
        #expect(ShareStatsSanitizer.modelName("openai/gpt-5acmeinternal") == nil)
        #expect(ShareStatsSanitizer.modelName("anthropic/claude-sonnetclient") == nil)
        #expect(ShareStatsSanitizer.modelName("acme/private-model-v2") == nil)
    }

    @Test
    func `overflowed model family totals stay unavailable`() throws {
        let rows = [
            SpendDashboardModel.ModelRow(
                rank: 1,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-5.4",
                totalTokens: Int.max,
                totalCost: Double.greatestFiniteMagnitude),
            SpendDashboardModel.ModelRow(
                rank: 2,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-5.4",
                totalTokens: 1,
                totalCost: Double.greatestFiniteMagnitude),
            SpendDashboardModel.ModelRow(
                rank: 3,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-5.4",
                totalTokens: 5,
                totalCost: 5),
        ]
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [
                SpendDashboardModel.ProviderRow(
                    id: "codex",
                    rank: 1,
                    provider: .codex,
                    displayName: "Codex",
                    totalTokens: 1,
                    totalCost: nil,
                    coveredDayCount: 7),
            ],
            models: rows,
            dailyPoints: [],
            dailyTokenPoints: [],
            totalTokens: 1,
            totalCost: nil,
            coveredDayCount: 0,
            chartDomain: Self.date...Self.date,
            modelHistoryCompleteness: .complete)
        let payload = try #require(ShareStatsBuilder.make(
            model: SpendDashboardModel(requestedDays: 7, groups: [group])))

        #expect(payload.topModels.isEmpty)
    }

    @Test
    func `empty dashboard has no share payload`() {
        #expect(ShareStatsBuilder.make(model: SpendDashboardModel(requestedDays: 30, groups: [])) == nil)
    }

    @Test
    func `cost only dashboard has no share payload`() {
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [
                SpendDashboardModel.ProviderRow(
                    id: "codex",
                    rank: 1,
                    provider: .codex,
                    displayName: "Codex",
                    totalTokens: nil,
                    totalCost: 4,
                    coveredDayCount: 7),
            ],
            models: [],
            dailyPoints: [],
            dailyTokenPoints: [],
            totalTokens: nil,
            totalCost: 4,
            coveredDayCount: 7,
            chartDomain: Self.date...Self.date,
            modelHistoryCompleteness: .complete)

        #expect(ShareStatsBuilder.make(
            model: SpendDashboardModel(requestedDays: 7, groups: [group])) == nil)
    }

    @Test
    func `cost only models do not enter token usage rankings`() throws {
        let model = SpendDashboardModel(requestedDays: 7, groups: [
            SpendDashboardModel.CurrencyGroup(
                currencyCode: "USD",
                providers: [
                    SpendDashboardModel.ProviderRow(
                        id: "codex",
                        rank: 1,
                        provider: .codex,
                        displayName: "Codex",
                        totalTokens: 10,
                        totalCost: .nan,
                        coveredDayCount: 7),
                ],
                models: [
                    SpendDashboardModel.ModelRow(
                        rank: 1,
                        provider: .codex,
                        providerName: "Codex",
                        modelName: "gpt-5.4",
                        totalTokens: 10,
                        totalCost: .infinity),
                    SpendDashboardModel.ModelRow(
                        rank: 2,
                        provider: .codex,
                        providerName: "Codex",
                        modelName: "gpt-5.4-mini",
                        totalTokens: nil,
                        totalCost: 2),
                    SpendDashboardModel.ModelRow(
                        rank: 3,
                        provider: .codex,
                        providerName: "Codex",
                        modelName: "gpt-5.4-nano",
                        totalTokens: nil,
                        totalCost: nil),
                ],
                dailyPoints: [],
                dailyTokenPoints: [],
                totalTokens: 10,
                totalCost: -.infinity,
                coveredDayCount: 7,
                chartDomain: Self.date...Self.date,
                modelHistoryCompleteness: .complete),
        ])
        let payload = try #require(ShareStatsBuilder.make(model: model))

        #expect(payload.providers.first?.estimatedCost == nil)
        #expect(payload.topModels.first?.totalTokens == 10)
        #expect(payload.topModels.first?.estimatedCost == nil)
        #expect(payload.topModels.count == 1)
        #expect(payload.currencies.first?.estimatedCost == nil)
        #expect(!ShareStatsFormatting.text(payload, style: .modelActivity).lowercased().contains("nan"))
        #expect(!ShareStatsFormatting.text(payload, style: .modelActivity).lowercased().contains("inf"))
    }

    @Test
    func `complete source models remain visible when group history is partial`() throws {
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [
                SpendDashboardModel.ProviderRow(
                    id: "codex",
                    rank: 1,
                    provider: .codex,
                    displayName: "Codex",
                    totalTokens: 10,
                    totalCost: 2,
                    coveredDayCount: 7),
            ],
            models: [
                SpendDashboardModel.ModelRow(
                    rank: 1,
                    provider: .codex,
                    providerName: "Codex",
                    modelName: "gpt-5.4",
                    totalTokens: 10,
                    totalCost: 2),
            ],
            dailyPoints: [],
            dailyTokenPoints: [],
            totalTokens: nil,
            totalCost: nil,
            coveredDayCount: 7,
            chartDomain: Self.date...Self.date,
            modelHistoryCompleteness: .incomplete)
        let payload = try #require(ShareStatsBuilder.make(
            model: SpendDashboardModel(requestedDays: 7, groups: [group])))

        #expect(payload.providers.count == 1)
        #expect(payload.topModels.map(\.modelName) == ["GPT-5.4"])
        #expect(!payload.modelRouteCoverageIsComplete)
        #expect(ShareStatsFormatting.text(payload, style: .modelActivity)
            .contains("Model route history is partial"))
    }

    @Test
    func `token complete model route survives unavailable pricing through dashboard builder`() throws {
        let entry = CostUsageDailyReport.Entry(
            date: Self.isoDay(Self.date),
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 10,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: [
                .init(modelName: "anthropic/claude-sonnet-4", costUSD: nil, totalTokens: 10),
            ])
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: nil,
            currencyCode: "USD",
            historyDays: 30,
            daily: [entry],
            updatedAt: Self.date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let dashboard = SpendDashboardModel.build(
            inputs: [
                .init(
                    id: "openrouter",
                    provider: .openrouter,
                    displayName: "OpenRouter",
                    snapshot: snapshot),
            ],
            requestedDays: 7,
            now: Self.date,
            calendar: calendar)
        let group = try #require(dashboard.groups.first)
        let payload = try #require(ShareStatsBuilder.make(model: dashboard))

        #expect(group.models.isEmpty)
        #expect(group.tokenModels.map(\.modelName) == ["anthropic/claude-sonnet-4"])
        #expect(group.tokenModels.map(\.totalTokens) == [10])
        #expect(group.tokenModels.map(\.totalCost) == [nil])
        #expect(payload.topModels.map(\.modelName) == ["Claude Sonnet 4"])
        #expect(payload.topModels.map(\.sourceName) == ["OpenRouter"])
        #expect(payload.topModels.map(\.estimatedCost) == [nil])
    }

    @Test
    func `selected window keeps quiet trailing days`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let exclusiveEnd = try #require(calendar.date(byAdding: .day, value: 7, to: Self.date))
        let expectedEnd = try #require(calendar.date(byAdding: .day, value: 6, to: Self.date))
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [
                SpendDashboardModel.ProviderRow(
                    id: "codex",
                    rank: 1,
                    provider: .codex,
                    displayName: "Codex",
                    totalTokens: 10,
                    totalCost: 1,
                    coveredDayCount: 7),
            ],
            models: [],
            dailyPoints: [],
            dailyTokenPoints: [
                SpendDashboardModel.DailyTokenPoint(
                    sourceID: "codex",
                    provider: .codex,
                    providerName: "Codex",
                    day: Self.date,
                    tokens: 10),
            ],
            totalTokens: 10,
            totalCost: 1,
            coveredDayCount: 7,
            chartDomain: Self.date...exclusiveEnd,
            modelHistoryCompleteness: .complete)
        let payload = try #require(ShareStatsBuilder.make(
            model: SpendDashboardModel(requestedDays: 7, groups: [group])))

        #expect(calendar.startOfDay(for: payload.periodEnd) == calendar.startOfDay(for: expectedEnd))
        #expect(payload.dailyTokens.map(\.day) == [Self.date])
    }

    @Test
    func `partial daily source coverage stays explicit`() throws {
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [
                SpendDashboardModel.ProviderRow(
                    id: "codex",
                    rank: 1,
                    provider: .codex,
                    displayName: "Codex",
                    totalTokens: 10,
                    totalCost: 1,
                    coveredDayCount: 7),
                SpendDashboardModel.ProviderRow(
                    id: "openrouter",
                    rank: 2,
                    provider: .openrouter,
                    displayName: "OpenRouter",
                    totalTokens: nil,
                    totalCost: nil,
                    coveredDayCount: 0),
            ],
            models: [],
            dailyPoints: [],
            dailyTokenPoints: [
                SpendDashboardModel.DailyTokenPoint(
                    sourceID: "codex",
                    provider: .codex,
                    providerName: "Codex",
                    day: Self.date,
                    tokens: 10),
            ],
            totalTokens: nil,
            totalCost: nil,
            coveredDayCount: 0,
            chartDomain: Self.date...Self.date,
            modelHistoryCompleteness: .incomplete)
        let payload = try #require(ShareStatsBuilder.make(
            model: SpendDashboardModel(requestedDays: 7, groups: [group])))

        #expect(payload.dailySourceCount == 1)
        #expect(payload.dailyFullSourceCount == 1)
        #expect(!payload.dailyCoverageIsComplete)
        #expect(ShareStatsFormatting.text(payload, style: .modelActivity)
            .contains("at least 1 of 7 days active"))
    }

    @Test
    func `seven of thirty covered days stay partial`() throws {
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [
                SpendDashboardModel.ProviderRow(
                    id: "codex",
                    rank: 1,
                    provider: .codex,
                    displayName: "Codex",
                    totalTokens: 10,
                    totalCost: 1,
                    coveredDayCount: 7),
            ],
            models: [],
            dailyPoints: [],
            dailyTokenPoints: [
                SpendDashboardModel.DailyTokenPoint(
                    sourceID: "codex",
                    provider: .codex,
                    providerName: "Codex",
                    day: Self.date,
                    tokens: 10),
            ],
            totalTokens: 10,
            totalCost: 1,
            coveredDayCount: 7,
            chartDomain: Self.date...Self.date,
            modelHistoryCompleteness: .complete)
        let payload = try #require(ShareStatsBuilder.make(
            model: SpendDashboardModel(requestedDays: 30, groups: [group])))

        #expect(payload.totalTokens == 10)
        #expect(payload.dailySourceCount == 1)
        #expect(payload.dailyFullSourceCount == 0)
        #expect(!payload.dailyCoverageIsComplete)
        #expect(ShareStatsFormatting.text(payload, style: .modelActivity)
            .contains("at least 1 of 30 days active"))
    }

    @Test
    func `daily token overflow is unavailable rather than zero`() throws {
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [
                SpendDashboardModel.ProviderRow(
                    id: "codex",
                    rank: 1,
                    provider: .codex,
                    displayName: "Codex",
                    totalTokens: Int.max,
                    totalCost: 1,
                    coveredDayCount: 1),
                SpendDashboardModel.ProviderRow(
                    id: "openrouter",
                    rank: 2,
                    provider: .openrouter,
                    displayName: "OpenRouter",
                    totalTokens: 1,
                    totalCost: 1,
                    coveredDayCount: 1),
            ],
            models: [],
            dailyPoints: [],
            dailyTokenPoints: [
                SpendDashboardModel.DailyTokenPoint(
                    sourceID: "codex",
                    provider: .codex,
                    providerName: "Codex",
                    day: Self.date,
                    tokens: Int.max),
                SpendDashboardModel.DailyTokenPoint(
                    sourceID: "openrouter",
                    provider: .openrouter,
                    providerName: "OpenRouter",
                    day: Self.date,
                    tokens: 1),
            ],
            totalTokens: nil,
            totalCost: 2,
            coveredDayCount: 1,
            chartDomain: Self.date...Self.date,
            modelHistoryCompleteness: .complete)
        let payload = try #require(ShareStatsBuilder.make(
            model: SpendDashboardModel(requestedDays: 1, groups: [group])))

        #expect(payload.dailyCoverageIsComplete)
        #expect(payload.dailyTokens == [ShareStatsDailyPayload(day: Self.date, totalTokens: nil)])
        #expect(payload.hasUnavailableDailyTotals)
        #expect(ShareStatsFormatting.text(payload, style: .modelActivity)
            .contains("at least 0 of 1 days active"))
    }

    @Test(arguments: [1, 4, 8, 20]) @MainActor
    func `same model stays distinct across many source instances`(sourceCount: Int) throws {
        let providers = (0..<sourceCount).map { index in
            SpendDashboardModel.ProviderRow(
                id: "openrouter:\(index)",
                rank: index + 1,
                provider: .openrouter,
                displayName: "unsafe account label \(index)",
                totalTokens: 10,
                totalCost: 1,
                coveredDayCount: 7)
        }
        let models = (0..<sourceCount).map { index in
            SpendDashboardModel.ModelRow(
                sourceID: "openrouter:\(index)",
                rank: index + 1,
                provider: .openrouter,
                providerName: "OpenRouter",
                sourceName: "unsafe account label \(index)",
                modelName: "anthropic/claude-sonnet-4",
                totalTokens: 10,
                totalCost: 1)
        }
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: providers,
            models: models,
            dailyPoints: [],
            dailyTokenPoints: [],
            totalTokens: sourceCount * 10,
            totalCost: Double(sourceCount),
            coveredDayCount: 7,
            chartDomain: Self.date...Self.date,
            modelHistoryCompleteness: .complete)
        let payload = try #require(ShareStatsBuilder.make(
            model: SpendDashboardModel(requestedDays: 7, groups: [group])))

        #expect(payload.providers.count == sourceCount)
        #expect(payload.topModels.count == sourceCount)
        #expect(Set(payload.topModels.map(\.sourceID)).count == sourceCount)
        #expect(payload.topModels.allSatisfy { $0.modelName == "Claude Sonnet 4" })
        #expect(payload.topModels.allSatisfy { !$0.sourceName.contains("unsafe") })

        let compactPNG = try #require(ShareStatsRenderer.pngData(
            for: payload,
            style: .modelActivity,
            pixelSize: CGSize(width: 300, height: 158)))
        let bitmap = try #require(NSBitmapImageRep(data: compactPNG))
        #expect(bitmap.pixelsWide == 300)
        #expect(bitmap.pixelsHigh == 158)
        #expect(Self.sampledColorCount(bitmap) > 8)
    }

    @Test
    func `model route identifiers cannot collide through separators`() {
        let first = SpendDashboardModel.ModelRow(
            sourceID: "openrouter:team",
            rank: 1,
            provider: .openrouter,
            providerName: "OpenRouter",
            modelName: "foo",
            totalTokens: 1,
            totalCost: 1)
        let second = SpendDashboardModel.ModelRow(
            sourceID: "openrouter",
            rank: 2,
            provider: .openrouter,
            providerName: "OpenRouter",
            modelName: "team:foo",
            totalTokens: 1,
            totalCost: 1)

        #expect(first.id != second.id)
    }

    @Test @MainActor
    func `renderer creates nonblank social card PNGs at share sizes`() throws {
        let payload = try #require(ShareStatsBuilder.make(model: Self.proofDashboard))
        #expect(ShareStatsCardView.size == CGSize(width: 1200, height: 630))
        #expect(payload.providers.count == 4)
        #expect(payload.topModels.count == 4)
        #expect(payload.dailyCoverageIsComplete)
        #expect(payload.tokenCoverageIsComplete)

        let proofDirectory = ProcessInfo.processInfo.environment["CODEXBAR_SHARE_STATS_PROOF_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let proofDirectory {
            try FileManager.default.createDirectory(
                at: proofDirectory,
                withIntermediateDirectories: true)
        }
        for (size, filename) in [
            (CGSize(width: 1200, height: 630), "share-stats-1200x630.png"),
            (CGSize(width: 600, height: 315), "share-stats-600x315.png"),
            (CGSize(width: 300, height: 158), "share-stats-300x158.png"),
        ] {
            let data = try #require(ShareStatsRenderer.pngData(
                for: payload,
                style: .modelActivity,
                pixelSize: size))
            #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == Int(size.width))
            #expect(bitmap.pixelsHigh == Int(size.height))
            #expect(Self.sampledColorCount(bitmap) > 8)
            #expect(Self.minimumSampledAlpha(bitmap) > 0.99)
            if let proofDirectory {
                try data.write(to: proofDirectory.appendingPathComponent(filename), options: .atomic)
            }
        }
        if let proofDirectory {
            let accessibleText = ShareStatsFormatting.text(payload, style: .modelActivity) + "\n"
            try accessibleText.write(
                to: proofDirectory.appendingPathComponent("share-stats.txt"),
                atomically: true,
                encoding: .utf8)
        }
    }

    @Test @MainActor
    func `summary card remains the default export while model activity is opt in`() throws {
        let payload = try #require(ShareStatsBuilder.make(model: Self.proofDashboard))

        #expect(ShareStatsCardStyle.defaultStyle == .summary)
        #expect(ShareStatsFormatting.text(payload).hasPrefix("My AI subscriptions"))
        #expect(ShareStatsFormatting.text(payload, style: .modelActivity).hasPrefix("You kept the models busy"))

        let defaultPNG = try #require(ShareStatsRenderer.pngData(for: payload))
        let summaryPNG = try #require(ShareStatsRenderer.pngData(for: payload, style: .summary))
        let activityPNG = try #require(ShareStatsRenderer.pngData(for: payload, style: .modelActivity))
        #expect(defaultPNG == summaryPNG)
        #expect(defaultPNG != activityPNG)
    }

    @Test @MainActor
    func `activity levels preserve zero and scale to five steps`() {
        #expect(ShareStatsModelActivityCardView.activityLevel(totalTokens: 0, maximum: 100) == 0)
        #expect(ShareStatsModelActivityCardView.activityLevel(totalTokens: 1, maximum: 100) == 1)
        #expect(ShareStatsModelActivityCardView.activityLevel(totalTokens: 50, maximum: 100) == 3)
        #expect(ShareStatsModelActivityCardView.activityLevel(totalTokens: 100, maximum: 100) == 5)
    }

    @Test
    func `overall token total becomes unavailable on overflow`() {
        #expect(ShareStatsBuilder.combinedTotalTokens([Int.max, 1]) == nil)
        #expect(ShareStatsBuilder.combinedTotalTokens([10, nil]) == nil)
        #expect(ShareStatsBuilder.combinedTotalTokens([10, 20]) == 30)
    }
}

extension ShareStatsTests {
    private static let date = Date(timeIntervalSince1970: 1_783_382_400)

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func sampledColorCount(_ bitmap: NSBitmapImageRep) -> Int {
        var sampledRGB: Set<UInt32> = []
        let xStride = max(1, bitmap.pixelsWide / 50)
        let yStride = max(1, bitmap.pixelsHigh / 30)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStride) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: xStride) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = UInt32((color.redComponent * 255).rounded())
                let green = UInt32((color.greenComponent * 255).rounded())
                let blue = UInt32((color.blueComponent * 255).rounded())
                sampledRGB.insert((red << 16) | (green << 8) | blue)
            }
        }
        return sampledRGB.count
    }

    private static func minimumSampledAlpha(_ bitmap: NSBitmapImageRep) -> CGFloat {
        var minimum: CGFloat = 1
        let xStride = max(1, bitmap.pixelsWide / 50)
        let yStride = max(1, bitmap.pixelsHigh / 30)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStride) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: xStride) {
                guard let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent else { continue }
                minimum = min(minimum, alpha)
            }
        }
        return minimum
    }

    private static func subscriptionName(
        provider: UsageProvider,
        rawName: String,
        accountOrganization: String? = nil) -> ShareStatsSubscriptionName?
    {
        ShareStatsSubscriptionName.from(
            snapshot: self.snapshot(
                provider: provider,
                rawName: rawName,
                accountOrganization: accountOrganization),
            provider: provider)
    }

    private static func snapshot(
        provider: UsageProvider,
        rawName: String,
        accountOrganization: String? = nil) -> UsageSnapshot
    {
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: nil,
            accountOrganization: accountOrganization,
            loginMethod: rawName)
        return UsageSnapshot(primary: nil, secondary: nil, updatedAt: self.date, identity: identity)
    }

    private static var dashboard: SpendDashboardModel {
        self.dashboard(models: ["gpt-5.4"])
    }

    private static var proofDashboard: SpendDashboardModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let start = calendar.startOfDay(for: self.date)
        let exclusiveEnd = calendar.date(byAdding: .day, value: 30, to: start) ?? start
        let sources = [
            ProofSource(id: "codex", provider: .codex, name: "Codex", model: "gpt-5.4", tokens: 8_000_000, cost: 94),
            ProofSource(
                id: "openrouter",
                provider: .openrouter,
                name: "OpenRouter",
                model: "anthropic/claude-sonnet-4",
                tokens: 7_000_000,
                cost: 140),
            ProofSource(
                id: "kimi",
                provider: .kimi,
                name: "Kimi",
                model: "moonshotai/kimi-k2.5",
                tokens: 4_000_000,
                cost: 22),
            ProofSource(
                id: "zai",
                provider: .zai,
                name: "Z.ai",
                model: "z-ai/glm-4.5",
                tokens: 2_700_000,
                cost: 18),
        ]
        let dailyTokenPoints = (0..<30).flatMap { dayOffset in
            sources.enumerated().compactMap { index, source -> SpendDashboardModel.DailyTokenPoint? in
                guard (dayOffset + index) % 5 != 0,
                      let day = calendar.date(byAdding: .day, value: dayOffset, to: start)
                else { return nil }
                return SpendDashboardModel.DailyTokenPoint(
                    sourceID: source.id,
                    provider: source.provider,
                    providerName: source.name,
                    day: day,
                    tokens: (index + 1) * (dayOffset + 3) * 18500)
            }
        }
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: sources.enumerated().map { index, source in
                SpendDashboardModel.ProviderRow(
                    id: source.id,
                    rank: index + 1,
                    provider: source.provider,
                    displayName: source.name,
                    totalTokens: source.tokens,
                    totalCost: source.cost,
                    coveredDayCount: 30)
            },
            models: sources.enumerated().map { index, source in
                SpendDashboardModel.ModelRow(
                    sourceID: source.id,
                    rank: index + 1,
                    provider: source.provider,
                    providerName: source.name,
                    sourceName: source.name,
                    modelName: source.model,
                    totalTokens: source.tokens,
                    totalCost: source.cost)
            },
            dailyPoints: [],
            dailyTokenPoints: dailyTokenPoints,
            totalTokens: sources.reduce(0) { $0 + $1.tokens },
            totalCost: sources.reduce(0) { $0 + $1.cost },
            coveredDayCount: 30,
            chartDomain: start...exclusiveEnd,
            modelHistoryCompleteness: .complete)
        return SpendDashboardModel(requestedDays: 30, groups: [group])
    }

    private static func dashboard(models: [String]) -> SpendDashboardModel {
        SpendDashboardModel(requestedDays: 30, groups: [
            SpendDashboardModel.CurrencyGroup(
                currencyCode: "GBP",
                providers: [
                    SpendDashboardModel.ProviderRow(
                        id: "claude",
                        rank: 1,
                        provider: .claude,
                        displayName: "Claude",
                        totalTokens: 300,
                        totalCost: 12,
                        coveredDayCount: 10),
                ],
                models: [
                    SpendDashboardModel.ModelRow(
                        rank: 1,
                        provider: .claude,
                        providerName: "Claude",
                        modelName: "claude-sonnet-4",
                        totalTokens: 1000,
                        totalCost: 1),
                ],
                dailyPoints: [],
                dailyTokenPoints: [
                    SpendDashboardModel.DailyTokenPoint(
                        sourceID: "claude",
                        provider: .claude,
                        providerName: "Claude",
                        day: self.date,
                        tokens: 300),
                ],
                totalTokens: 300,
                totalCost: 12,
                coveredDayCount: 10,
                chartDomain: self.date...self.date,
                modelHistoryCompleteness: .complete),
            SpendDashboardModel.CurrencyGroup(
                currencyCode: "USD",
                providers: [
                    SpendDashboardModel.ProviderRow(
                        id: "codex:one",
                        rank: 1,
                        provider: .codex,
                        displayName: "Codex · #1",
                        totalTokens: 200,
                        totalCost: 4,
                        coveredDayCount: 30),
                    SpendDashboardModel.ProviderRow(
                        id: "cursor",
                        rank: 2,
                        provider: .cursor,
                        displayName: "Cursor",
                        totalTokens: nil,
                        totalCost: nil,
                        coveredDayCount: 0),
                ],
                models: models.enumerated().map { index, name in
                    SpendDashboardModel.ModelRow(
                        rank: index + 1,
                        provider: .codex,
                        providerName: "Codex",
                        modelName: name,
                        totalTokens: 200,
                        totalCost: 4)
                },
                dailyPoints: [],
                dailyTokenPoints: [
                    SpendDashboardModel.DailyTokenPoint(
                        sourceID: "codex:one",
                        provider: .codex,
                        providerName: "Codex · #1",
                        day: self.date,
                        tokens: 200),
                ],
                totalTokens: nil,
                totalCost: nil,
                coveredDayCount: 0,
                chartDomain: self.date...self.date,
                modelHistoryCompleteness: .complete),
        ])
    }
}
