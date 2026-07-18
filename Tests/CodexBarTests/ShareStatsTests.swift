import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ShareStatsTests {
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
        #expect(payload.totalTokens == nil)
        #expect(payload.currencies == [
            ShareStatsCurrencyPayload(currencyCode: "GBP", estimatedCost: 12, coveredDayCount: 10),
            ShareStatsCurrencyPayload(currencyCode: "USD", estimatedCost: nil, coveredDayCount: 0),
        ])
        #expect(payload.providers.map(\.providerName) == ["Claude", "Codex · #1", "Cursor"])
        #expect(payload.providers.map(\.subscriptionName) == ["Max", "Pro 20x", "Cursor Pro"])
        #expect(payload.providers.last?.estimatedCost == nil)
        #expect(payload.topModels.map(\.modelName).prefix(2) == ["Claude", "GPT"])
        #expect(payload.dailyTokens == [ShareStatsDailyPayload(day: Self.date, totalTokens: 500)])
        #expect(payload.dailySourceCount == 2)

        let text = ShareStatsFormatting.text(payload)
        #expect(text.contains("You kept the models busy · last 30 days"))
        #expect(text.contains("1 of 30 days active"))
        #expect(text.contains("Estimated token spend: £12.00 · pricing for 2 of 3 sources"))
        #expect(text.contains("Top model + source pairs:"))
        #expect(text.contains("Claude · Claude"))
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
        let text = ShareStatsFormatting.text(payload)

        #expect(payload.topModels.map(\.modelName) == ["Claude", "GPT"])
        #expect(payload.topModels.last?.totalTokens == 400)
        #expect(payload.topModels.last?.estimatedCost == 8)
        #expect(payload.providers.map(\.subscriptionName) == ["Max", nil, nil])
        #expect(!text.contains("person@example.com"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("550e8400"))
        #expect(!text.contains("secret project"))
        #expect(!text.contains("abcdefabcdef"))
        #expect(!text.contains("intranet"))
        #expect(!text.contains("acme"))
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
        #expect(ShareStatsSanitizer.modelName("us.amazon.nova-2-lite-v1:0") == "Amazon Nova")
        #expect(ShareStatsSanitizer.modelName("global.anthropic.claude-sonnet-4-v1:0") == "Claude")
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
                modelName: "gpt-5.4-mini",
                totalTokens: 1,
                totalCost: Double.greatestFiniteMagnitude),
            SpendDashboardModel.ModelRow(
                rank: 3,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-5.4-nano",
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
        #expect(!ShareStatsFormatting.text(payload).lowercased().contains("nan"))
        #expect(!ShareStatsFormatting.text(payload).lowercased().contains("inf"))
    }

    @Test
    func `partial model history does not enter shared rankings`() throws {
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
            totalTokens: nil,
            totalCost: nil,
            coveredDayCount: 7,
            chartDomain: Self.date...Self.date,
            modelHistoryCompleteness: .incomplete)
        let payload = try #require(ShareStatsBuilder.make(
            model: SpendDashboardModel(requestedDays: 7, groups: [group])))

        #expect(payload.providers.count == 1)
        #expect(payload.topModels.isEmpty)
    }

    @Test @MainActor
    func `renderer creates social card PNG`() throws {
        let payload = try #require(ShareStatsBuilder.make(model: Self.dashboard))
        let data = try #require(ShareStatsRenderer.pngData(for: payload))

        #expect(ShareStatsCardView.size == CGSize(width: 1200, height: 630))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 1200)
        #expect(bitmap.pixelsHigh == 630)
        var sampledRGB: Set<UInt32> = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 19) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 23) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = UInt32((color.redComponent * 255).rounded())
                let green = UInt32((color.greenComponent * 255).rounded())
                let blue = UInt32((color.blueComponent * 255).rounded())
                sampledRGB.insert((red << 16) | (green << 8) | blue)
                if sampledRGB.count > 8 {
                    break
                }
            }
            if sampledRGB.count > 8 {
                break
            }
        }
        #expect(sampledRGB.count > 1)
    }

    @Test @MainActor
    func `activity levels preserve zero and scale to five steps`() {
        #expect(ShareStatsCardView.activityLevel(totalTokens: 0, maximum: 100) == 0)
        #expect(ShareStatsCardView.activityLevel(totalTokens: 1, maximum: 100) == 1)
        #expect(ShareStatsCardView.activityLevel(totalTokens: 50, maximum: 100) == 3)
        #expect(ShareStatsCardView.activityLevel(totalTokens: 100, maximum: 100) == 5)
    }

    @Test
    func `overall token total becomes unavailable on overflow`() {
        #expect(ShareStatsBuilder.combinedTotalTokens([Int.max, 1]) == nil)
        #expect(ShareStatsBuilder.combinedTotalTokens([10, nil]) == nil)
        #expect(ShareStatsBuilder.combinedTotalTokens([10, 20]) == 30)
    }

    private static let date = Date(timeIntervalSince1970: 1_783_382_400)

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
