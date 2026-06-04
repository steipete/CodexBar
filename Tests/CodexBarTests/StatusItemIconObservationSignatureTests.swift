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
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
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
    func `store icon observation signature ignores non visual snapshot churn`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-snapshot-metadata")
        defer { controller.releaseStatusItemsForTesting() }

        let baseline = controller.storeIconObservationSignature()

        store._setSnapshotForTesting(
            Self.makeSnapshot(
                provider: .codex,
                email: "rotated-account@example.com",
                updatedAt: Date(timeIntervalSince1970: 200)),
            provider: .codex)

        let signature = controller.storeIconObservationSignature()

        #expect(signature == baseline)
        #expect(!signature.contains("rotated-account@example.com"))
    }

    @Test
    func `merged store icon observation signature ignores non primary snapshot churn`() throws {
        let (settings, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-merged-secondary-snapshot")
        defer { controller.releaseStatusItemsForTesting() }

        let registry = ProviderRegistry.shared
        let claudeMetadata = try #require(registry.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: true)
        store._setSnapshotForTesting(
            Self.makeSnapshot(provider: .claude, email: "claude@example.com"),
            provider: .claude)
        let baseline = controller.storeIconObservationSignature()

        store._setSnapshotForTesting(
            Self.makeSnapshot(
                provider: .claude,
                email: "changed@example.com",
                primaryUsedPercent: 99,
                secondaryUsedPercent: 88,
                updatedAt: Date(timeIntervalSince1970: 300)),
            provider: .claude)

        #expect(controller.storeIconObservationSignature() == baseline)
    }

    @Test
    func `store icon observation signature changes when icon percentages change`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-percent-change")
        defer { controller.releaseStatusItemsForTesting() }

        let baseline = controller.storeIconObservationSignature()

        store._setSnapshotForTesting(
            Self.makeSnapshot(
                provider: .codex,
                email: "icon@example.com",
                primaryUsedPercent: 42,
                secondaryUsedPercent: 63),
            provider: .codex)

        #expect(controller.storeIconObservationSignature() != baseline)
    }

    @Test
    func `store icon observation signature changes when credit fallback changes`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-credit-fallback")
        defer { controller.releaseStatusItemsForTesting() }

        store._setSnapshotForTesting(
            Self.makeSnapshot(
                provider: .codex,
                email: "icon@example.com",
                primaryUsedPercent: 100,
                secondaryUsedPercent: 20),
            provider: .codex)
        store.credits = CreditsSnapshot(remaining: 80, events: [], updatedAt: Date(timeIntervalSince1970: 100))
        let baseline = controller.storeIconObservationSignature()

        store.credits = CreditsSnapshot(remaining: 42, events: [], updatedAt: Date(timeIntervalSince1970: 200))

        #expect(controller.storeIconObservationSignature() != baseline)
    }

    @Test
    func `store icon observation signature ignores unused credit balance`() {
        let (_, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-unused-credits")
        defer { controller.releaseStatusItemsForTesting() }

        store.credits = CreditsSnapshot(remaining: 80, events: [], updatedAt: Date(timeIntervalSince1970: 100))
        let baseline = controller.storeIconObservationSignature()

        store.credits = CreditsSnapshot(remaining: 42, events: [], updatedAt: Date(timeIntervalSince1970: 200))

        #expect(controller.storeIconObservationSignature() == baseline)
    }

    @Test
    func `merged store icon observation signature changes when non primary status changes`() throws {
        let (settings, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-merged-secondary-status")
        defer { controller.releaseStatusItemsForTesting() }

        let registry = ProviderRegistry.shared
        let claudeMetadata = try #require(registry.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: true)
        let baseline = controller.storeIconObservationSignature()

        store.statuses[.claude] = ProviderStatus(
            indicator: .major,
            description: "Claude status issue",
            updatedAt: Date(timeIntervalSince1970: 20))

        #expect(controller.storeIconObservationSignature() != baseline)
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

    private static func makeSnapshot(
        provider: UsageProvider,
        email: String,
        primaryUsedPercent: Double = 10,
        secondaryUsedPercent: Double = 20,
        updatedAt: Date = Date(timeIntervalSince1970: 100))
        -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: primaryUsedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: secondaryUsedPercent,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "plus"))
    }
}
