import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ShareStatsTests {
    @Test
    func `descriptor share plan labels preserve the legacy central table`() throws {
        var fingerprint: UInt64 = 1_469_598_103_934_665_603
        for descriptor in ProviderDescriptorRegistry.all where !descriptor.metadata.sharePlanLabels.isEmpty {
            Self.hash(descriptor.id.rawValue, into: &fingerprint)
            for key in descriptor.metadata.sharePlanLabels.keys.sorted() {
                Self.hash(key, into: &fingerprint)
                try Self.hash(#require(descriptor.metadata.sharePlanLabels[key]), into: &fingerprint)
            }
        }

        #expect(fingerprint == 2_500_333_924_415_227_190)
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
        #expect(payload.totalTokensIsPartial)
        #expect(payload.currencies == [
            ShareStatsCurrencyPayload(currencyCode: "GBP", estimatedCost: 12, coveredDayCount: 10),
            ShareStatsCurrencyPayload(currencyCode: "USD", estimatedCost: 4, coveredDayCount: 0, isPartial: true),
        ])
        #expect(payload.providers.map(\.providerName) == ["Claude", "Codex · #1", "Cursor"])
        #expect(payload.providers.map(\.subscriptionName) == ["Max", "Pro 20x", "Cursor Pro"])
        #expect(payload.providers.last?.estimatedCost == nil)
        #expect(payload.spendReportingProviderCount == 2)
        #expect(payload.topModels.map(\.modelName).prefix(2) == ["Claude Sonnet 4", "GPT 5.4"])

        let text = ShareStatsFormatting.text(payload)
        #expect(text.contains("GBP: £12.00 estimated · coverage 10/30 days"))
        #expect(text.contains("Claude · Max: 300 tokens · ~£12.00 est · 10/30 days"))
        #expect(text.contains("USD: ~$4.00 estimated · coverage 0/30 days"))
        #expect(text.contains("Cursor · Cursor Pro: Spend unavailable"))
        #expect(text.contains("2/3 connected services report spend"))
        #expect(!text.contains("£12.00 +"))
    }

    @Test
    func `overview roster keeps every connected service in the flex card`() throws {
        let roster = [
            ShareStatsProviderRosterEntry(provider: .codex, providerName: "Codex", currencyCode: "USD"),
            ShareStatsProviderRosterEntry(provider: .claude, providerName: "Claude", currencyCode: "USD"),
            ShareStatsProviderRosterEntry(provider: .openrouter, providerName: "OpenRouter", currencyCode: "USD"),
            ShareStatsProviderRosterEntry(provider: .gemini, providerName: "Gemini", currencyCode: "USD"),
            ShareStatsProviderRosterEntry(provider: .grok, providerName: "Grok", currencyCode: "USD"),
            ShareStatsProviderRosterEntry(provider: .cursor, providerName: "Cursor", currencyCode: "USD"),
        ]
        let payload = try #require(ShareStatsBuilder.make(model: Self.dashboard, providerRoster: roster))

        #expect(payload.providers.map(\.provider) == roster.map(\.provider))
        #expect(payload.providers.count == 6)
        #expect(payload.spendReportingProviderCount == 2)
        #expect(payload.providers.last?.estimatedCost == nil)
        #expect(payload.totalTokens == 500)
        #expect(payload.totalTokensIsPartial)
        #expect(payload.currencies.allSatisfy { currency in currency.isPartial })
        #expect(ShareStatsFormatting.text(payload).contains("~500 tracked tokens"))
        #expect(ShareStatsFormatting.text(payload).contains("2/6 connected services report spend"))
    }

    @Test
    func `duplicate accounts cannot mask a connected provider with unavailable usage`() throws {
        let model = SpendDashboardModel(requestedDays: 30, groups: [
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
                        id: "codex:two",
                        rank: 2,
                        provider: .codex,
                        displayName: "Codex · #2",
                        totalTokens: 300,
                        totalCost: 6,
                        coveredDayCount: 30),
                ],
                models: [],
                dailyPoints: [],
                totalTokens: 500,
                totalCost: 10,
                coveredDayCount: 30,
                chartDomain: Self.date...Self.date,
                modelHistoryCompleteness: .complete),
        ])
        let roster = [
            ShareStatsProviderRosterEntry(provider: .codex, providerName: "Codex", currencyCode: "USD"),
            ShareStatsProviderRosterEntry(
                provider: .openrouter,
                providerName: "OpenRouter",
                currencyCode: "USD"),
        ]

        let payload = try #require(ShareStatsBuilder.make(model: model, providerRoster: roster))

        #expect(payload.totalTokens == 500)
        #expect(payload.totalTokensIsPartial)
        #expect(payload.currencies.count == 1)
        #expect(payload.currencies.first?.isPartial == true)
        #expect(payload.spendReportingProviderCount == 1)
        #expect(payload.providers.count == 2)
    }

    @Test
    func `twenty connected services remain accounted for without overflowing the flex card`() throws {
        let roster = Array(UsageProvider.allCases.prefix(20)).map { provider in
            ShareStatsProviderRosterEntry(
                provider: provider,
                providerName: ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue,
                currencyCode: "USD")
        }
        let payload = try #require(ShareStatsBuilder.make(model: Self.dashboard, providerRoster: roster))

        #expect(roster.count == 20)
        #expect(payload.providers.count == 20)
        #expect(ShareStatsCardView.providerDisplayLimit(for: payload.providers.count) == 4)
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

        #expect(payload.topModels.map(\.modelName) == ["Claude Sonnet 4", "GPT 5.4"])
        #expect(payload.topModels.last?.totalTokens == 200)
        #expect(payload.topModels.last?.estimatedCost == 4)
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
        #expect(ShareStatsSanitizer.modelName("us.amazon.nova-2-lite-v1:0") == "Amazon Nova 2 Lite")
        #expect(ShareStatsSanitizer.modelName("global.anthropic.claude-sonnet-4-v1:0") == "Claude Sonnet 4")
    }

    @Test
    func `share model labels preserve first class variants and routed OpenRouter ids`() {
        #expect(ShareStatsSanitizer.modelName("claude-fable-5") == "Claude Fable 5")
        #expect(ShareStatsSanitizer.modelName("claude-opus-4-6") == "Claude Opus 4.6")
        #expect(ShareStatsSanitizer.modelName("claude-sonnet-4-6") == "Claude Sonnet 4.6")
        #expect(ShareStatsSanitizer.modelName("anthropic/claude-sonnet-4-6") == "Claude Sonnet 4.6")
        #expect(ShareStatsSanitizer.modelName("openai/gpt-5.4-mini") == "GPT 5.4 Mini")
        #expect(ShareStatsSanitizer.modelName("openai/gpt-5.6-sol") == "GPT 5.6 Sol")
        #expect(ShareStatsSanitizer.modelName("openai/gpt-5.6-terra") == "GPT 5.6 Terra")
        #expect(ShareStatsSanitizer.modelName("openai/gpt-5.6-luna") == "GPT 5.6 Luna")
        #expect(ShareStatsSanitizer.modelName("openai/gpt-4o") == "GPT 4o")
        #expect(ShareStatsSanitizer.modelName("google/gemini-2.5-pro") == "Gemini 2.5 Pro")
        #expect(ShareStatsSanitizer.modelName("moonshotai/kimi-k2.5") == "Kimi K2.5")
        #expect(ShareStatsSanitizer.modelName("acme/private-model-v2") == nil)
        #expect(ShareStatsSanitizer.modelName("acme/gpt-secret-project") == nil)
    }

    @Test @MainActor
    func `routed OpenRouter models remain distinct in the share ranking`() throws {
        let modelRows = [
            ("anthropic/claude-fable-5", 900),
            ("anthropic/claude-opus-4-6", 800),
            ("anthropic/claude-sonnet-4-6", 700),
            ("openai/gpt-5.4-mini", 600),
            ("gpt-5.4-mini", 100),
            ("google/gemini-2.5-pro", 500),
            ("x-ai/grok-4-fast", 400),
        ]
        let dashboard = SpendDashboardModel(requestedDays: 30, groups: [
            SpendDashboardModel.CurrencyGroup(
                currencyCode: "USD",
                providers: [
                    SpendDashboardModel.ProviderRow(
                        id: "openrouter",
                        rank: 1,
                        provider: .openrouter,
                        displayName: "OpenRouter",
                        totalTokens: 4000,
                        totalCost: 40,
                        coveredDayCount: 30),
                ],
                models: modelRows.enumerated().map { index, row in
                    SpendDashboardModel.ModelRow(
                        rank: index + 1,
                        provider: .openrouter,
                        providerName: "OpenRouter",
                        modelName: row.0,
                        totalTokens: row.1,
                        totalCost: Double(row.1) / 100)
                },
                dailyPoints: [],
                totalTokens: 4000,
                totalCost: 40,
                coveredDayCount: 30,
                chartDomain: Self.date...Self.date,
                modelHistoryCompleteness: .complete),
        ])

        let payload = try #require(ShareStatsBuilder.make(model: dashboard))
        #expect(payload.topModels.map(\.modelName) == [
            "Claude Fable 5",
            "Claude Opus 4.6",
            "Claude Sonnet 4.6",
            "GPT 5.4 Mini",
            "Gemini 2.5 Pro",
            "Grok 4 Fast",
        ])
        #expect(payload.topModels.allSatisfy { $0.provider == .openrouter })
        #expect(payload.topModels.first { $0.modelName == "GPT 5.4 Mini" }?.totalTokens == 700)
        #expect(ShareStatsCardView.modelSectionDetail(for: payload.topModels.count) == "3 OF 6 · BY TOKENS")
        #expect(ShareStatsFormatting.text(payload).contains("+1 more models ranked in local stats"))
        #expect(try #require(ShareStatsRenderer.pngData(for: payload)).isEmpty == false)
    }

    @Test
    func `overflowed model family totals stay unavailable`() throws {
        let rows = [
            SpendDashboardModel.ModelRow(
                rank: 1,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-5.4-mini",
                totalTokens: Int.max,
                totalCost: Double.greatestFiniteMagnitude),
            SpendDashboardModel.ModelRow(
                rank: 2,
                provider: .codex,
                providerName: "Codex",
                modelName: "openai/gpt-5.4-mini",
                totalTokens: 1,
                totalCost: Double.greatestFiniteMagnitude),
            SpendDashboardModel.ModelRow(
                rank: 3,
                provider: .codex,
                providerName: "Codex",
                modelName: "chatgpt-5.4-mini",
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
    func `provider rows leave room for overflow summary`() {
        #expect(ShareStatsCardView.providerDisplayLimit(for: 5) == 5)
        #expect(ShareStatsCardView.providerDisplayLimit(for: 6) == 4)
        #expect(ShareStatsCardView.providerDisplayLimit(for: 12) == 4)
        #expect(ShareStatsCardView.providerDisplayLimit(for: 20) == 4)
    }

    @Test @MainActor
    func `model colors use provider identity instead of decorated account name`() throws {
        let payload = try #require(ShareStatsBuilder.make(model: Self.dashboard))
        let codexModel = try #require(payload.topModels.first { $0.provider == .codex })

        #expect(ShareStatsCardView.providerPaletteIndex(for: codexModel, providers: payload.providers) == 1)
    }

    @Test
    func `overall token total becomes unavailable on overflow`() {
        #expect(ShareStatsBuilder.combinedTotalTokens([Int.max, 1]) == nil)
        #expect(ShareStatsBuilder.combinedTotalTokens([10, nil]) == nil)
        #expect(ShareStatsBuilder.combinedTotalTokens([10, 20]) == 30)
    }

    private static let date = Date(timeIntervalSince1970: 1_783_382_400)

    private static func hash(_ value: String, into fingerprint: inout UInt64) {
        for byte in value.utf8 {
            fingerprint = (fingerprint ^ UInt64(byte)) &* 1_099_511_628_211
        }
        fingerprint = (fingerprint ^ 0xFF) &* 1_099_511_628_211
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
            providerID: provider.instanceID,
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
                totalTokens: nil,
                totalCost: nil,
                coveredDayCount: 0,
                chartDomain: self.date...self.date,
                modelHistoryCompleteness: .complete),
        ])
    }
}
