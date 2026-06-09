import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `menu card sizing uses displayed hosting view`() throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
        }

        let controller = self.makeHeightCacheController()
        defer { controller.releaseStatusItemsForTesting() }

        let counter = MenuCardRepresentableCounter()
        let item = controller.makeMenuCardItem(
            CountingMenuCardRepresentable(counter: counter),
            id: "countingCard-\(UUID().uuidString)",
            width: 320,
            heightCacheScope: "counting",
            heightCacheFingerprint: "counting-\(UUID().uuidString)")
        let view = try #require(item.view)

        view.layoutSubtreeIfNeeded()

        #expect(counter.makeViewCount == 1)
    }

    @Test
    func `menu card height cache is reused for stable card content`() {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        let firstKeys = Set(controller.menuCardHeightCache.keys)

        #expect(!firstKeys.isEmpty)

        controller.populateMenu(menu, provider: .codex)
        #expect(Set(controller.menuCardHeightCache.keys) == firstKeys)

        controller.invalidateMenus()
        #expect(Set(controller.menuCardHeightCache.keys) == firstKeys)
    }

    @Test
    func `standard menu width cache is reused for stable action rows`() {
        let controller = self.makeHeightCacheController()
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        let firstCache = controller.measuredStandardMenuWidthCache

        #expect(!firstCache.isEmpty)
        #expect(firstCache.keys.allSatisfy {
            $0.contains("font=\(StatusItemController.menuCardHeightTextScaleToken())")
        })

        controller.populateMenu(menu, provider: .codex)
        #expect(controller.measuredStandardMenuWidthCache == firstCache)
    }

    @Test
    func `fingerprinted menu card height cache survives content version invalidation`() {
        let controller = self.makeHeightCacheController()
        defer { controller.releaseStatusItemsForTesting() }

        var measureCount = 0
        let first = controller.cachedMenuCardHeight(
            for: "menuCard",
            scope: UsageProvider.codex.rawValue,
            width: 320,
            fingerprint: "content:stable")
        {
            measureCount += 1
            return 42
        }

        controller.invalidateMenus()

        let second = controller.cachedMenuCardHeight(
            for: "menuCard",
            scope: UsageProvider.codex.rawValue,
            width: 320,
            fingerprint: "content:stable")
        {
            measureCount += 1
            return 99
        }

        #expect(first == 42)
        #expect(second == 42)
        #expect(measureCount == 1)
    }

    @Test
    func `fingerprinted menu card height cache remeasures when content changes`() {
        let controller = self.makeHeightCacheController()
        defer { controller.releaseStatusItemsForTesting() }

        var measureCount = 0
        let first = controller.cachedMenuCardHeight(
            for: "menuCard",
            scope: UsageProvider.codex.rawValue,
            width: 320,
            fingerprint: "content:a")
        {
            measureCount += 1
            return 42
        }
        let second = controller.cachedMenuCardHeight(
            for: "menuCard",
            scope: UsageProvider.codex.rawValue,
            width: 320,
            fingerprint: "content:b")
        {
            measureCount += 1
            return 99
        }

        #expect(first == 42)
        #expect(second == 99)
        #expect(measureCount == 2)
    }

    @Test
    func `unfingerprinted menu card height cache remains content version scoped`() {
        let controller = self.makeHeightCacheController()
        defer { controller.releaseStatusItemsForTesting() }

        var measureCount = 0
        let first = controller.cachedMenuCardHeight(
            for: "menuCard",
            scope: UsageProvider.codex.rawValue,
            width: 320)
        {
            measureCount += 1
            return 42
        }

        controller.invalidateMenus()

        let second = controller.cachedMenuCardHeight(
            for: "menuCard",
            scope: UsageProvider.codex.rawValue,
            width: 320)
        {
            measureCount += 1
            return 99
        }

        #expect(first == 42)
        #expect(second == 99)
        #expect(measureCount == 2)
    }

    @Test
    func `menu invalidation prunes old version scoped height cache entries`() {
        let controller = self.makeHeightCacheController()
        defer { controller.releaseStatusItemsForTesting() }

        _ = controller.cachedMenuCardHeight(
            for: "versioned",
            scope: UsageProvider.codex.rawValue,
            width: 320)
        {
            42
        }
        _ = controller.cachedMenuCardHeight(
            for: "fingerprinted",
            scope: UsageProvider.codex.rawValue,
            width: 320,
            fingerprint: "content:stable")
        {
            99
        }

        controller.invalidateMenus()

        #expect(controller.menuCardHeightCache.keys.allSatisfy { !$0.fingerprint.hasPrefix("version:") })
        #expect(controller.menuCardHeightCache.keys.contains { $0.fingerprint == "content:stable" })
    }

    @Test
    func `menu card height cache scopes same row ids by provider`() {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex || provider == .claude)
        }

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 12,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: "claude@example.com",
                    accountOrganization: nil,
                    loginMethod: "Claude Pro")),
            provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        controller.populateMenu(menu, provider: .claude)

        let scopes = Set(controller.menuCardHeightCache.keys.map(\.scope))
        #expect(scopes.contains(UsageProvider.codex.rawValue))
        #expect(scopes.contains(UsageProvider.claude.rawValue))
    }

    private func makeHeightCacheController() -> StatusItemController {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        return StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
    }
}

@MainActor
private final class MenuCardRepresentableCounter {
    var makeViewCount = 0
}

private struct CountingMenuCardRepresentable: NSViewRepresentable {
    let counter: MenuCardRepresentableCounter

    func makeNSView(context: Context) -> NSTextField {
        self.counter.makeViewCount += 1
        return NSTextField(labelWithString: "Counted")
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        _ = nsView
        _ = context
    }
}
