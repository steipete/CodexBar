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
        settings.menuBarShowsHighestUsage = false
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = false
        settings.selectedMenuProvider = .codex

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
        settings.selectedMenuProvider = .codex
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
    func `store icon observation signature tracks selected copilot budget`() throws {
        let (settings, store, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-copilot-budget")
        defer { controller.releaseStatusItemsForTesting() }

        let registry = ProviderRegistry.shared
        let codexMetadata = try #require(registry.metadata[.codex])
        let copilotMetadata = try #require(registry.metadata[.copilot])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: false)
        settings.setProviderEnabled(provider: .copilot, metadata: copilotMetadata, enabled: true)
        settings.selectedMenuProvider = .copilot
        settings.copilotBudgetExtrasEnabled = true
        settings.copilotIconSecondaryWindowID = "copilot-budget-agent"

        store._setSnapshotForTesting(
            Self.makeCopilotSnapshot(budgetUsedPercent: 25),
            provider: .copilot)
        let baseline = controller.storeIconObservationSignature()

        store._setSnapshotForTesting(
            Self.makeCopilotSnapshot(budgetUsedPercent: 75),
            provider: .copilot)

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
    func `merged store icon observation signature ignores non primary status changes`() throws {
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

    @Test
    func `store icon observation signature changes when hide critters toggles`() {
        let (settings, _, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-hide-critters")
        defer { controller.releaseStatusItemsForTesting() }

        settings.menuBarHidesCritters = false
        let baseline = controller.storeIconObservationSignature()

        settings.menuBarHidesCritters = true

        #expect(controller.storeIconObservationSignature() != baseline)
    }

    @Test
    func `updateIcons reuses a precomputed store icon signature instead of recomputing it`() {
        let (_, _, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-precomputed-reuse")
        defer { controller.releaseStatusItemsForTesting() }

        let precomputed = "precomputed-store-icon-signature-sentinel"
        controller.updateIcons(precomputedStoreIconSignature: precomputed)

        // A supplied signature must be stored verbatim; if updateIcons recomputed it, the gate would
        // never equal the sentinel value.
        #expect(controller.lastObservedStoreIconWorkSignature == precomputed)
    }

    @Test
    func `updateIcons recomputes the store icon signature when none is provided`() {
        let (_, _, controller) = self.makeController(
            suiteName: "StatusItemIconObservationSignatureTests-recompute-default")
        defer { controller.releaseStatusItemsForTesting() }

        controller.updateIcons()

        #expect(controller.lastObservedStoreIconWorkSignature == controller.storeIconObservationSignature())
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

    private static func makeCopilotSnapshot(budgetUsedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "copilot-budget-agent",
                    title: "Budget - Copilot Agent Premium Requests",
                    window: RateWindow(
                        usedPercent: budgetUsedPercent,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: Date(timeIntervalSince1970: 100),
            identity: ProviderIdentitySnapshot(
                providerID: .copilot,
                accountEmail: "copilot@example.com",
                accountOrganization: nil,
                loginMethod: "individual"))
    }
}
