import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CodexMachineMenuTests {
    private static func result() async throws -> CodexIdentifiedResult {
        let end: Int64 = 1_728_000_100_000
        var ledger = CodexRequestLedger(startUnixMs: end - 86_400_000 - 100_000, endUnixMs: end)
        ledger.records = [.init(
            id: String(repeating: "a", count: 64),
            timestampUnixMs: end - 1000,
            inputTokens: 100,
            cacheReadTokens: 20,
            outputTokens: 10,
            reasoningTokens: 3,
            model: "gpt-5",
            pricingMode: "standard")]
        let source = ledger
        return try await CodexIdentifiedCollection.collect(
            remotes: [],
            startUnixMs: source.startUnixMs,
            endUnixMs: end,
            includeSourceSubtotals: true,
            local: { source },
            fetchRemote: { _ in
                throw RemoteCodexCostError.unavailable
            })
    }
}

private actor MachineMenuCollectionRecorder {
    var loadCount = 0
    func load(_ result: CodexIdentifiedResult) -> CodexIdentifiedResult {
        self.loadCount += 1
        return result
    }
}

extension CodexMachineMenuTests {
    @Test(CodexCredentialFixtures())
    func `unavailable settings or disabled Codex rejects the machine action`() throws {
        let fixture = try MachineMenuFixture()
        defer { fixture.stop() }
        let model = try #require(fixture.controller.menuCardModel(for: .codex))
        let menu = NSMenu()
        fixture.controller.addCostMenuItems(to: menu, model: model, submenu: nil, width: 350)
        let action = try #require(menu.items.first { $0.action != nil })
        _ = fixture.controller.perform(action.action)
        #expect(!fixture.dashboard.machineExpanded)
        #expect(fixture.dashboard.machineRevealRevision == 0)
        enableTestProviders([], settings: fixture.settings)
        #expect(!fixture.controller.showsMachineCostMenu(for: .codex))
        var opened: SettingsPane?
        fixture.controller.settingsOpenHandler = { opened = $0 }
        _ = fixture.controller.perform(action.action)
        #expect(opened == nil)
        #expect(!fixture.dashboard.machineExpanded)
        let disabledMenu = NSMenu()
        fixture.controller.addMachineCostMenuItems(to: disabledMenu, provider: .codex)
        #expect(disabledMenu.items.isEmpty)
        enableTestProviders([.codex], settings: fixture.settings)
        let previousRequest = SessionUsageNavigation.shared.request
        defer { SessionUsageNavigation.shared.request = previousRequest }
        SessionUsageNavigation.shared.request = .init(
            context: .init(
                providerName: "Codex",
                windowLabel: "Today",
                sessions: [],
                currencyCode: "USD",
                costMultiplier: 1,
                timeZone: .gmt),
            sessionID: nil)
        for _ in 0..<5 {
            _ = fixture.controller.perform(action.action)
        }
        #expect(opened == .usageSpend)
        #expect(SessionUsageNavigation.shared.request == nil)
        #expect(fixture.dashboard.machineExpanded && fixture.dashboard.machineRevealRevision == 5)
        fixture.settings.costSummaryDisplayStyle = .inlineSummary
        #expect(!fixture.controller.showsMachineCostMenu(for: .codex))
        fixture.settings.costSummaryDisplayStyle = .both
        fixture.settings.costUsageEnabled = false
        #expect(!fixture.controller.showsMachineCostMenu(for: .codex))
        #expect(!fixture.controller.showsMachineCostMenu(for: .claude))
    }

    @Test(CodexCredentialFixtures(), arguments: ["merged", "sectioned", "stacked"])
    func `machine action follows local content once in every layout`(layout: String) throws {
        let fixture = try MachineMenuFixture()
        defer { fixture.stop() }
        let menu = NSMenu()
        if layout == "stacked" {
            let display = MenuCardCodexAmbientCostTests.display(count: 2)
            fixture.controller.addCodexAccountMenuCards(
                display,
                to: menu,
                captureMenu: menu,
                context: MenuCardCodexAmbientCostTests.context(display: display))
        } else {
            if layout == "sectioned" {
                fixture.store._setTokenSnapshotForTesting(.init(
                    sessionTokens: 110,
                    sessionCostUSD: 1,
                    last30DaysTokens: 110,
                    last30DaysCostUSD: 1,
                    daily: [.init(
                        date: "2024-10-04",
                        inputTokens: 100,
                        outputTokens: 10,
                        totalTokens: 110,
                        costUSD: 1,
                        modelsUsed: nil,
                        modelBreakdowns: nil)],
                    updatedAt: Date(timeIntervalSince1970: 1_728_000_100)), provider: .codex)
            }
            fixture.controller.populateMenu(menu, provider: .codex)
        }
        #expect(menu.items.filter { $0.title == "By machine…" }.count == 1)
        let localID = layout == "stacked" ? "menuCard-1" : layout == "merged" ? "menuCard" : "menuCardCost"
        let localIndex = try #require(menu.items.firstIndex { $0.representedObject as? String == localID })
        let actionIndex = try #require(menu.items.firstIndex { $0.title == "By machine…" })
        #expect(localIndex < actionIndex)
    }
}

@MainActor
private struct MachineMenuFixture {
    let settings: SettingsStore
    let store: UsageStore
    let dashboard: SpendDashboardController
    let controller: StatusItemController

    init(
        result: CodexIdentifiedResult? = nil,
        recorder: MachineMenuCollectionRecorder? = nil) throws
    {
        let root = CodexCredentialFixtures.root
        let environment = [
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent("codex").path,
            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
        ]
        let settings = testSettingsStore(
            suiteName: #function, userDefaults: InMemoryUserDefaults(), config: testConfigWithAllProvidersDisabled())
        settings._test_codexAccountSnapshotLoader = { source in
            .init(
                storedAccounts: [],
                activeStoredAccount: nil,
                liveSystemAccount: nil,
                matchingStoredAccountForLiveSystemAccount: nil,
                activeSource: source,
                hasUnreadableAddedAccountStore: false)
        }
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        enableTestProviders([.codex], settings: settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let dashboard = SpendDashboardController(
            userDefaults: InMemoryUserDefaults(),
            requestBuilder: { _ in .init(
                configuration: .init(costUsageEnabled: false, providerIDs: [], codexAccountIdentities: []),
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: Date(timeIntervalSince1970: 1_728_000_100),
                force: false) },
            machineLoader: { _, _, _, _ in
                guard let result else { throw CancellationError() }
                return await recorder?.load(result) ?? result
            },
            nowProvider: { Date(timeIntervalSince1970: 1_728_000_100) })
        store.sharedSpendDashboardControllerStorage = dashboard
        self.settings = settings
        self.store = store
        self.dashboard = dashboard
        self.controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar(),
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
    }

    func stop() {
        self.controller.releaseStatusItemsForTesting()
        self.dashboard.stop()
        self.settings.configFileWatcher?.stop()
    }
}

extension CodexMachineMenuTests {
    @Test(CodexCredentialFixtures())
    func `actual detail view collects on menu reveal and clears on collapse`() async throws {
        let recorder = MachineMenuCollectionRecorder()
        let fixture = try await MachineMenuFixture(result: Self.result(), recorder: recorder)
        defer { fixture.stop() }
        let menu = fixture.controller.makeMenu(for: .codex)
        fixture.controller.populateMenu(menu, provider: .codex)
        fixture.controller.menuWillOpen(menu)
        defer { fixture.controller.menuDidClose(menu) }
        #expect(await recorder.loadCount == 0)
        let action = try #require(menu.items.first { $0.title == "By machine…" })
        fixture.controller.settingsOpenHandler = { _ in }
        _ = fixture.controller.perform(action.action)
        let hosting = NSHostingView(rootView: MachineSpendDetail(
            settings: fixture.settings, store: fixture.store, controller: fixture.dashboard)
            .frame(width: 800, height: 500))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(3)
        while fixture.dashboard.machineResult == nil, Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(fixture.dashboard.machineResult != nil)
        #expect(await recorder.loadCount == 1)
        fixture.dashboard.machineExpanded = false
        let collapseDeadline = Date().addingTimeInterval(3)
        while fixture.dashboard.machineResult != nil, Date() < collapseDeadline {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.dashboard.machineResult == nil)
        #expect(await recorder.loadCount == 1)
    }
}
