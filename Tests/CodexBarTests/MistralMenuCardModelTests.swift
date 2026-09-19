import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MistralMenuCardModelTests {
    @Test
    @MainActor
    func `allowance labels reach legacy menus and widgets`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = testSettingsStore(
            suiteName: #function, userDefaults: InMemoryUserDefaults(), config: testConfigWithAllProvidersDisabled())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: root.path, fileExists: { _ in false }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetSnapshotURL: root.appendingPathComponent("widget.json"))
        store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date()), provider: .mistral)
        let descriptor = MenuDescriptor.build(
            provider: .mistral,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let lines = descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(text, _) = entry else { return nil }
            return text
        }
        #expect(lines.contains { $0.contains("Included API") })
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }
        store.persistWidgetSnapshot(reason: "mistral-allowance-label-test")
        await store.widgetSnapshotPersistTask?.value
        let entry = try #require(saved?.entries.first { $0.provider == .mistral })
        #expect(entry.usageRows?.first?.title == "Included API")
        #expect(entry.usageRows?.first?.percentLeft == 80)
    }

    @Test
    func `mistral credit balance renders like deepseek balance`() throws {
        let now = Date()
        let credits = MistralCreditsSnapshot(
            walletAmount: 0,
            creditNotesAmount: 0,
            ongoingUsageBalance: 0,
            currency: "USD")
        let snapshot = MistralUsageSnapshot(
            totalCost: 0,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 0,
            credits: credits,
            startDate: nil,
            endDate: nil,
            updatedAt: now)
            .toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.mistral])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .mistral,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.title == "Balance")
        #expect(primary.statusText == "$0.00")
        #expect(primary.resetText == nil)
        #expect(primary.detailText == nil)
    }

    @Test
    func `mistral included API window relabels primary lane`() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 1.1,
                windowMinutes: nil,
                resetsAt: ISO8601DateParser.parse("2026-10-01T00:00:00.000Z"),
                resetDescription: "€0.28 / €25.50 · €25.22 left"),
            secondary: nil,
            updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.mistral])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .mistral,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.title == "Included API")
    }

    @Test
    func `mistral credit balance renders separately from primary percent lane`() throws {
        let now = Date()
        let credits = MistralCreditsSnapshot(
            walletAmount: 10,
            creditNotesAmount: 2.5,
            ongoingUsageBalance: 0,
            currency: "USD")
        let usage = MistralUsageSnapshot(
            totalCost: 0,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 0,
            credits: credits,
            startDate: nil,
            endDate: nil,
            updatedAt: now)
            .toUsageSnapshot()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 73,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: "API spend this month"),
            secondary: nil,
            tertiary: nil,
            mistralUsage: usage.mistralUsage,
            updatedAt: now,
            identity: usage.identity)
        let metadata = try #require(ProviderDefaults.metadata[.mistral])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .mistral,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.id == "mistral-balance")
        #expect(primary.statusText == "$12.50")
        #expect(primary.detailText == nil)
        #expect(primary.resetText == nil)

        let percentMetric = try #require(model.metrics.dropFirst().first)
        #expect(percentMetric.id == "primary")
        #expect(percentMetric.percent == 27)
        #expect(percentMetric.detailText == "API spend this month")
    }

    @Test
    func `mistral model surfaces monthly cost as primary detail text`() throws {
        let now = Date()
        let resetsAt = now.addingTimeInterval(3 * 24 * 60 * 60)
        let identity = ProviderIdentitySnapshot(
            providerID: .mistral,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: resetsAt,
                resetDescription: "€1.2345 this month"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.mistral])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .mistral,
            metadata: metadata,
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

        let primary = try #require(model.metrics.first)
        #expect(primary.detailText == "€1.2345 this month")
        #expect(primary.resetText?.hasPrefix("Resets") == true)
    }

    @Test(arguments: [false, true])
    func `mistral monthly plan shows included amount detail`(hasReset: Bool) throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "mistral-monthly-plan",
                    title: "Monthly Plan",
                    window: RateWindow(
                        usedPercent: 0,
                        windowMinutes: nil,
                        resetsAt: hasReset ? now.addingTimeInterval(3 * 24 * 60 * 60) : nil,
                        resetDescription: "€0.00 / €255.00 · €255.00 left")),
            ],
            updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.mistral])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .mistral,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let monthlyPlan = try #require(model.metrics.first { $0.id == "mistral-monthly-plan" })
        #expect(monthlyPlan.detailText == "€0.00 / €255.00 · €255.00 left")
        #expect(monthlyPlan.resetText?.hasPrefix("Resets") == (hasReset ? true : nil))
    }
}
