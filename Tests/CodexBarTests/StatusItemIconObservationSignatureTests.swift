import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemIconObservationSignatureTests {
    private func makeController(suiteName: String) -> (SettingsStore, UsageStore, StatusItemController) {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = true
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = false
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(Self.makeSnapshot(provider: .codex, email: "icon@example.com"), provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        return (settings, store, controller)
    }

    @Test
    func `store icon observation signature ignores refresh and status metadata churn`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-refresh-metadata")
        defer { controller.releaseStatusItemsForTesting() }

        store.statuses[.codex] = ProviderStatus(
            indicator: .none,
            description: "initial",
            updatedAt: Date(timeIntervalSince1970: 10))
        let baseline = controller.storeIconObservationSignature()

        store.isRefreshing = true
        store.statuses[.codex] = ProviderStatus(
            indicator: .none,
            description: "same indicator, newer timestamp",
            updatedAt: Date(timeIntervalSince1970: 20))

        #expect(controller.storeIconObservationSignature() == baseline)
    }

    @Test
    func `store icon observation signature changes when status indicator changes`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-status-indicator")
        defer { controller.releaseStatusItemsForTesting() }

        store.statuses[.codex] = ProviderStatus(
            indicator: .none,
            description: "initial",
            updatedAt: Date(timeIntervalSince1970: 10))
        let baseline = controller.storeIconObservationSignature()

        store.statuses[.codex] = ProviderStatus(
            indicator: .major,
            description: "major outage",
            updatedAt: Date(timeIntervalSince1970: 20))

        #expect(controller.storeIconObservationSignature() != baseline)
    }

    private static func makeSnapshot(provider: UsageProvider, email: String) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 100),
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "plus"))
    }
}
