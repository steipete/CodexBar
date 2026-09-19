import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Codex spend is scanned from an ambient `CODEX_HOME` shared by every account, so it belongs to
/// the machine rather than to any one card. The multi-account menu therefore renders it once, from
/// the live card model, instead of repeating the same total under every account.
@MainActor
struct MenuCardCodexAmbientCostTests {
    struct Fixture {
        let store: UsageStore
        let settings: SettingsStore
        let fetcher: UsageFetcher
    }

    static func makeFixture(costUsageEnabled: Bool = true, seedAmbientCost: Bool = true) -> Fixture {
        let settings = testSettingsStore(suiteName: "MenuCardCodexAmbientCostTests")
        settings._test_managedCodexAccountStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambient-cost-managed-\(UUID().uuidString).json")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = costUsageEnabled
        let environment = ["HOME": FileManager.default.temporaryDirectory.path]
        let fetcher = UsageFetcher(environment: environment)
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(homeDirectory: FileManager.default.temporaryDirectory.path, cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store._test_widgetSnapshotSaveOverride = { _ in }
        if seedAmbientCost {
            store._setTokenSnapshotForTesting(
                CostUsageTokenSnapshot(
                    sessionTokens: 123,
                    sessionCostUSD: 0.12,
                    last30DaysTokens: 456,
                    last30DaysCostUSD: 1.23,
                    daily: [.init(
                        date: String(ISO8601DateFormatter().string(from: Date()).prefix(10)),
                        inputTokens: 100,
                        outputTokens: 23,
                        totalTokens: 123,
                        costUSD: 0.12,
                        modelsUsed: ["fictional-test-model"],
                        modelBreakdowns: nil)],
                    updatedAt: Date()),
                provider: .codex)
        }
        return Fixture(store: store, settings: settings, fetcher: fetcher)
    }

    private static func accountCardModel(
        _ controller: StatusItemController,
        email: String) -> UsageMenuCardView.Model?
    {
        controller.menuCardModel(
            for: .codex,
            context: .account(.init(info: AccountInfo(email: email, plan: nil))))
    }

    @Test
    func `the shared cost section sources the ambient ledger from the live card`() throws {
        let fixture = Self.makeFixture()

        try withStatusItemControllerForTesting(
            store: fixture.store,
            settings: fixture.settings,
            fetcher: fixture.fetcher)
        { controller in
            let model = try #require(controller.menuCardModel(for: .codex))
            #expect(model.tokenUsage != nil)
        }
    }

    @Test
    func `codex account cards do not repeat the machine wide cost`() throws {
        let fixture = Self.makeFixture()

        try withStatusItemControllerForTesting(
            store: fixture.store,
            settings: fixture.settings,
            fetcher: fixture.fetcher)
        { controller in
            let first = try #require(Self.accountCardModel(controller, email: "first@example.com"))
            let second = try #require(Self.accountCardModel(controller, email: "second@example.com"))

            // Both the inline usage dashboard and the cost block are driven by `tokenUsage`, so a
            // per-card snapshot would render the same total twice per card and again per account.
            #expect(first.tokenUsage == nil)
            #expect(second.tokenUsage == nil)
            #expect(first.inlineUsageDashboard == nil)
            #expect(second.inlineUsageDashboard == nil)
            #expect(first.email == "first@example.com")
            #expect(second.email == "second@example.com")
        }
    }

    @Test
    func `the shared cost section is withheld when cost usage is disabled`() throws {
        let fixture = Self.makeFixture(costUsageEnabled: false)

        try withStatusItemControllerForTesting(
            store: fixture.store,
            settings: fixture.settings,
            fetcher: fixture.fetcher)
        { controller in
            let model = try #require(controller.menuCardModel(for: .codex))
            #expect(model.tokenUsage == nil)
        }
    }

    @Test
    func `only the ambient codex ledger counts as account agnostic`() {
        let fixture = Self.makeFixture(seedAmbientCost: false)

        // Ambient `~/.codex/sessions` scan: machine-wide, so it is rendered once for the menu.
        #expect(fixture.store.tokenCostIsAccountAgnostic(for: .codex))
        // Claude's cost is credential-scoped and belongs to a single account, so it is never
        // promoted to a menu-wide section.
        #expect(!fixture.store.tokenCostIsAccountAgnostic(for: .claude))
    }

    @Test(arguments: [2, 5], CostSummaryDisplayStyle.allCases)
    func `both account layouts honor the shared cost display mode`(count: Int, style: CostSummaryDisplayStyle) {
        let fixture = Self.makeFixture()
        fixture.settings.costSummaryDisplayStyle = style
        withStatusItemControllerForTesting(
            store: fixture.store,
            settings: fixture.settings,
            fetcher: fixture.fetcher)
        { controller in
            let display = Self.display(count: count)
            let context = Self.context(display: display)
            let menu = controller.makeMenu()
            controller.addCodexAccountMenuCards(display, to: menu, captureMenu: menu, context: context)
            let costRows = menu.items.filter { $0.representedObject as? String == "menuCardCost" }
            let dashboards = menu.items.filter { $0.representedObject as? String == "sharedCodexInlineCost" }
            #expect(costRows.count == (style.showsCostSubmenu ? 1 : 0))
            #expect(dashboards.count == (style.showsInlineSummary ? 1 : 0))
            if let cost = costRows.first {
                #expect(cost.title == StatusItemController.costMenuTitle)
                #expect(cost.submenu != nil)
            }
        }
    }

    @Test
    func `managed account history is not promoted to shared spend`() {
        let fixture = Self.makeFixture(seedAmbientCost: false)
        fixture.settings.codexLocalSessionCostLedgerEnabled = false
        fixture.settings.codexActiveSource = .managedAccount(id: UUID())
        #expect(!fixture.store.tokenCostIsAccountAgnostic(for: .codex))
        fixture.settings.codexLocalSessionCostLedgerEnabled = true
        #expect(fixture.store.tokenCostIsAccountAgnostic(for: .codex))
    }

    static func display(count: Int) -> CodexAccountMenuDisplay {
        let accounts = (1...count).map { index in
            CodexVisibleAccount(
                id: "synthetic-account-\(index)",
                email: "account\(index)@example.com",
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: index == 1,
                isLive: true,
                canReauthenticate: false,
                canRemove: false)
        }
        let snapshots = accounts.map { account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 20,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                error: nil,
                sourceLabel: "synthetic")
        }
        return CodexAccountMenuDisplay(
            accounts: accounts,
            snapshots: snapshots,
            activeVisibleAccountID: accounts.first?.id,
            layout: .stacked)
    }

    static func context(display: CodexAccountMenuDisplay) -> StatusItemController.MenuCardContext {
        .init(
            currentProvider: .codex,
            selectedProvider: .codex,
            menuWidth: 310,
            codexAccountDisplay: display,
            tokenAccountDisplay: nil,
            openAIContext: .init(
                hasUsageBreakdown: false,
                hasCreditsHistory: false,
                hasCostHistory: false,
                canShowBuyCredits: false,
                hasOpenAIWebMenuItems: false))
    }
}
