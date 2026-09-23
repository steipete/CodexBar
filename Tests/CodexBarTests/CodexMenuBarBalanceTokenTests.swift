import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexMenuBarBalanceTokenTests {
    @Test
    func `custom Codex balance token shows authoritative workspace credits in status item and preview`() throws {
        let settings = testSettingsStore(
            suiteName: "CodexMenuBarBalanceTokenTests-workspace-balance",
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = UsageProvider.codex.instanceID
        settings.menuBarDisplayMode = .both
        settings.menuBarIconStyle = .iconAndPercent
        settings.usageBarsShowUsed = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic), .separatorDot, .balance]])
        settings.setMenuBarLayout(layout, for: nil)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 96,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(
            remaining: 1234.73,
            events: [],
            updatedAt: now,
            balanceReadSucceeded: true,
            creditsAvailable: true,
            balanceIsWorkspace: true)

        let statusItemData = controller.menuBarLayoutRenderData(
            provider: .codex,
            snapshot: snapshot,
            warningFlash: false,
            now: now)
        let previewData = MenuBarLayoutPreview(
            layout: layout,
            provider: .codex,
            settings: settings,
            store: store)
            .liveData(provider: .codex, snapshot: snapshot)

        #expect(statusItemData.balance == "1,235")
        #expect(previewData.balance == "1,235")

        // Exercise the observation wiring: the rate windows do not change when credits arrive later.
        let initialSignature = controller.storeIconObservationSignature()
        store.credits = CreditsSnapshot(
            remaining: 1233.49,
            events: [],
            updatedAt: now,
            creditsAvailable: true,
            balanceIsWorkspace: true)
        #expect(controller.storeIconObservationSignature() != initialSignature)
        #expect(controller.storeIconObservationSignature().contains("text=1,233"))
    }

    @Test
    func `stored balance token shows provider balance in status item and preview`() {
        let settings = self.makeSettings(
            suiteName: "CodexMenuBarBalanceTokenTests-deepseek-balance",
            provider: .deepseek)
        settings.menuBarIconStyle = .iconAndPercent
        let layout = MenuBarLayout(lines: [[.balance]])
        settings.setMenuBarLayout(layout, for: nil)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "¥2.23 (Paid: ¥2.23 / Granted: ¥0.00)"),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .deepseek)
        store._setErrorForTesting(nil, provider: .deepseek)

        let statusItemData = controller.menuBarLayoutRenderData(
            provider: .deepseek,
            snapshot: snapshot,
            warningFlash: false)
        let previewData = MenuBarLayoutPreview(
            layout: layout,
            provider: .deepseek,
            settings: settings,
            store: store)
            .liveData(provider: .deepseek, snapshot: snapshot)

        for data in [statusItemData, previewData] {
            let rendered = MenuBarLayoutRenderer().render(
                layout: layout,
                data: data,
                icon: nil,
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: true,
                    conditionals: [],
                    appearanceName: "aqua",
                    isDebugApp: false,
                    now: Date()))

            #expect(data.balance == "¥2.23")
            #expect(rendered.attributedTitle.string == "¥2.23")
        }

        // The layout signature tracks the balance so a later balance change repaints the icon.
        let initialSignature = controller.storeIconObservationSignature()
        store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "¥5.00 (Paid: ¥5.00 / Granted: ¥0.00)"),
            secondary: nil,
            updatedAt: Date()), provider: .deepseek)
        #expect(controller.storeIconObservationSignature() != initialSignature)
    }

    @Test
    func `menu bar display text uses hyper balance`() throws {
        let settings = self.makeSettings(
            suiteName: "CodexMenuBarBalanceTokenTests-hyper-balance",
            provider: .hyper)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(title: "Hypercredits", rows: [
                ProviderDetailSection.Row(label: "Balance", value: "42.5 HC"),
            ])],
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .hyper)
        store._setErrorForTesting(nil, provider: .hyper)

        #expect(controller.menuBarDisplayText(for: .hyper, snapshot: snapshot) == "42.5 HC")
    }

    @Test
    func `stored hyper icon and percent layout shows balance in status item and preview`() throws {
        let settings = self.makeSettings(
            suiteName: "CodexMenuBarBalanceTokenTests-hyper-layout-balance",
            provider: .hyper)
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .automatic)]])
        settings.setMenuBarLayout(layout, for: nil)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(title: "Hypercredits", rows: [
                ProviderDetailSection.Row(label: "Balance", value: "42.5 HC"),
            ])],
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .hyper)
        store._setErrorForTesting(nil, provider: .hyper)

        let statusItemData = controller.menuBarLayoutRenderData(
            provider: .hyper,
            snapshot: snapshot,
            warningFlash: false)
        let previewData = MenuBarLayoutPreview(
            layout: layout,
            provider: .hyper,
            settings: settings,
            store: store)
            .liveData(provider: .hyper, snapshot: snapshot)

        for data in [statusItemData, previewData] {
            let rendered = MenuBarLayoutRenderer().render(
                layout: layout,
                data: data,
                icon: NSImage(size: NSSize(width: 16, height: 16)),
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: true,
                    conditionals: [],
                    appearanceName: "aqua",
                    isDebugApp: false,
                    now: Date()))

            #expect(data.automatic == nil)
            #expect(data.automaticText == "42.5 HC")
            #expect(rendered.attributedTitle.string.hasSuffix("42.5 HC"))
        }
    }

    private func makeSettings(suiteName: String, provider: UsageProvider) -> SettingsStore {
        let settings = testSettingsStore(suiteName: suiteName, userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = provider.instanceID
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = true

        let registry = ProviderRegistry.shared
        if let metadata = registry.metadata[provider] {
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: true)
        }
        return settings
    }

    private func makeStoreAndController(settings: SettingsStore) -> (UsageStore, StatusItemController) {
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (store, controller)
    }
}
