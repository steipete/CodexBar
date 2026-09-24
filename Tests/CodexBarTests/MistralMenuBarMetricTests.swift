import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct MistralMenuBarMetricTests {
    @Test(arguments: [false, true])
    func `Mistral reset tokens show only real reset dates`(hasReset: Bool) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reset = hasReset ? now.addingTimeInterval(7200) : nil
        let window = MenuBarLayoutRenderWindow(RateWindow(
            usedPercent: 20,
            windowMinutes: nil,
            resetsAt: reset,
            resetDescription: "€10.00 / €50.00 · €40.00 left"))
        let text = MenuBarLayoutResetText(window: window, provider: .mistral, now: now)
        #expect(text.countdown == reset.map { UsageFormatter.resetCountdownDescription(from: $0, now: now) })
        #expect(text.absolute == reset.map { UsageFormatter.resetDescription(from: $0, now: now) })
    }

    @Test(arguments: [
        (MenuBarMetricPreference.automatic, "42%"),
        (.primary, "2%"),
        (.monthlyPlan, "42%"),
    ])
    func `Mistral automatic follows the most constrained allowance`(
        preference: MenuBarMetricPreference, expected: String)
    {
        let settings = testSettingsStore(
            suiteName: "MistralMenuBarMetricTests-mistral-included-api",
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = UsageProvider.mistral.instanceID
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = true
        settings.setMenuBarMetricPreference(preference, for: .mistral)
        let (store, controller) = Self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = MistralUsageSnapshot(
            totalCost: 1.2345,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 10000,
            totalOutputTokens: 5000,
            totalCachedTokens: 0,
            modelCount: 2,
            credits: MistralCreditsSnapshot(
                walletAmount: 20, creditNotesAmount: 0, ongoingUsageBalance: 1.2345, currency: "EUR"),
            startDate: nil,
            endDate: nil,
            updatedAt: Date())
            .toUsageSnapshot()
            .with(
                primary: RateWindow(
                    usedPercent: 2,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: "€0.51 / €25.50 · €24.99 left"),
                secondary: nil)
            .with(extraRateWindows: [NamedRateWindow(
                id: "mistral-monthly-plan",
                title: "Monthly Plan",
                window: RateWindow(usedPercent: 42, windowMinutes: nil, resetsAt: nil, resetDescription: nil))])

        store._setSnapshotForTesting(snapshot, provider: .mistral)
        store._setErrorForTesting(nil, provider: .mistral)

        let displayText = controller.menuBarDisplayText(for: .mistral, snapshot: snapshot)

        #expect(displayText == expected)
        #expect(MenuBarPercentWindowPreference.session.label(for: .mistral) == "Included API")
    }

    @Test
    func `Monthly Plan is offered as a named layout token when the allowance is known`() {
        let monthly = NamedRateWindow(
            id: MistralProviderDescriptor.monthlyPlanWindowID,
            title: MistralProviderDescriptor.monthlyPlanWindowTitle,
            window: RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: nil, resetDescription: nil))
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, extraRateWindows: [monthly], updatedAt: Date())

        let tokens = MenuBarLayoutNamedExtra.availableTokens(provider: .mistral, snapshot: snapshot)
        #expect(tokens == [.extraPercent(id: MistralProviderDescriptor.monthlyPlanWindowID)])
        #expect(tokens.first?.editorLabel(provider: .mistral) == "Monthly Plan %")

        let empty = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
        #expect(MenuBarLayoutNamedExtra.availableTokens(provider: .mistral, snapshot: empty).isEmpty)
    }

    private static func makeStoreAndController(settings: SettingsStore)
        -> (UsageStore, StatusItemController)
    {
        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (store, controller)
    }
}
