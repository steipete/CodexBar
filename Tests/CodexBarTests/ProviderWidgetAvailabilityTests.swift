import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarWidget

struct ProviderWidgetAvailabilityTests {
    @Test
    func `provider choice supports DeepSeek and OpenRouter`() {
        #expect(ProviderChoice(provider: .deepseek) == .deepseek)
        #expect(ProviderChoice.deepseek.provider == .deepseek)
        #expect(ProviderChoice(provider: .openrouter) == .openrouter)
        #expect(ProviderChoice.openrouter.provider == .openrouter)
    }

    @Test
    func `provider balance formatter renders DeepSeek and OpenRouter balances`() {
        for (provider, value) in [(UsageProvider.deepseek, "$9.32"), (.openrouter, "$60.00")] {
            let entry = Self.entry(provider: provider, balanceText: value)

            #expect(WidgetBalanceFormatter.providerBalance(for: entry) == WidgetBalanceLine(
                title: "Balance",
                value: value))
            #expect(CompactMetricFormatter.display(for: entry, metric: .credits) == CompactMetricDisplay(
                value: value,
                label: "Balance",
                detail: nil))
            #expect(WidgetMetricRows.rows(for: entry, size: .medium) == [WidgetMetricRow(
                id: "provider-balance",
                title: "Balance",
                value: value)])
            #expect(WidgetFallbackHero.make(for: entry) == WidgetFallbackHeroContent(
                value: value,
                caption: "Balance",
                detail: nil,
                consumedMetricID: "provider-balance"))
        }
    }

    @Test
    func `DeepSeek balance does not render as a quota bar`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .deepseek,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: "$15.00"),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            balanceText: "$15.00")

        #expect(WidgetUsageRow.rows(for: entry).isEmpty)
    }

    @Test
    func `OpenRouter retains its real quota alongside the credit balance`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .openrouter,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            balanceText: "$60.00")

        #expect(WidgetUsageRow.rows(for: entry).first?.percentLeft == 75)
        for size in [WidgetTileSize.small, .medium, .large] {
            #expect(WidgetMetricRows.rows(for: entry, size: size).contains {
                $0.id == "provider-balance" && $0.value == "$60.00"
            })
        }
    }

    @Test
    func `uncapped OpenRouter uses balance without inventing a quota`() {
        let entry = Self.entry(provider: .openrouter, balanceText: "$60.00")
        #expect(WidgetUsageRow.rows(for: entry).isEmpty)
        #expect(WidgetFallbackHero.make(for: entry)?.value == "$60.00")
    }

    @Test
    func `missing balance never becomes a zero balance or another provider metric`() {
        for value in [nil, "", "  \n "] {
            #expect(WidgetBalanceFormatter.providerBalance(
                for: Self.entry(provider: .openrouter, balanceText: value)) == nil)
        }
        #expect(WidgetBalanceFormatter.providerBalance(
            for: Self.entry(provider: .codex, balanceText: "$60.00")) == nil)
    }

    @Test
    func `provider balance survives snapshot JSON round trip`() throws {
        let snapshot = WidgetSnapshot(
            entries: [Self.entry(provider: .deepseek, balanceText: "$15.25")],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))

        #expect(decoded.entries.first?.provider == .deepseek)
        #expect(decoded.entries.first?.balanceText == "$15.25")
    }

    @Test
    func `legacy snapshot JSON without provider balance remains decodable`() throws {
        let snapshot = WidgetSnapshot(
            entries: [Self.entry(provider: .codex, balanceText: nil)],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let entries = object?["entries"] as? [[String: Any]]

        #expect(entries?.first?["balanceText"] == nil)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: encoded)
        #expect(decoded.entries.first?.provider == .codex)
        #expect(decoded.entries.first?.balanceText == nil)
    }

    private static func entry(
        provider: UsageProvider,
        balanceText: String?) -> WidgetSnapshot.ProviderEntry
    {
        WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            balanceText: balanceText)
    }
}

@MainActor
struct ProviderWidgetSnapshotTests {
    @Test
    func `widget snapshot publishes menu bar balances`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = testSettingsStore(
            suiteName: "ProviderWidgetSnapshotTests-provider-balances",
            config: testConfigWithAllProvidersDisabled())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: root.path, fileExists: { _ in false }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetSnapshotURL: root.appendingPathComponent("widget.json"))
        let updatedAt = Date(timeIntervalSince1970: 1_789_473_600)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: "$9.32 (Paid: $8.32 / Granted: $1.00)"),
                secondary: nil,
                updatedAt: updatedAt),
            provider: .deepseek)
        try store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                details: [ProviderDetailSection(
                    title: "Credits",
                    rows: [ProviderDetailSection.Row(label: "Remaining", value: "$60.00")])],
                updatedAt: updatedAt),
            provider: .openrouter)
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "provider-balance-test")
        await store.widgetSnapshotPersistTask?.value

        #expect(saved?.entries.first { $0.provider == .deepseek }?.balanceText == "$9.32")
        #expect(saved?.entries.first { $0.provider == .openrouter }?.balanceText == "$60.00")
    }
}
