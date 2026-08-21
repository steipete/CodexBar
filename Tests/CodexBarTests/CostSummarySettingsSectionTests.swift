import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CostSummarySettingsSectionTests {
    @Test
    func `cost settings explain reported and estimated sources`() {
        #expect(
            CostSummarySettingsSection.costDataExplanation()
                == "Costs may be provider-reported or estimated from token usage at public API prices. "
                + "Estimates are not subscription charges.")
    }

    @Test
    func `cost settings status providers come from ordered descriptor capabilities`() {
        #expect(CostSummarySettingsSection.costStatusProviders == [.claude, .codex, .cursor])
    }

    @Test
    func `Codex profile cost status hides incompatible raw snapshot until selected profile publishes`() {
        let (settings, store) = Self.makeCodexFixture(ambient: false)
        let profileA = "/tmp/cost-status-profile-a"
        let profileB = "/tmp/cost-status-profile-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let profileASnapshot = Self.snapshot(cost: 1)
        store._setTokenSnapshotForTesting(profileASnapshot, provider: .codex)
        let section = CostSummarySettingsSection(settings: settings, store: store)

        #expect(section.costStatusText(provider: .codex).contains(Self.formattedCost(1)))

        settings.codexActiveSource = .profileHome(path: profileB)

        #expect(store.tokenSnapshot(for: .codex) == profileASnapshot)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
        #expect(section.costStatusText(provider: .codex) == String(
            format: L("cost_status_no_data"),
            ProviderDescriptorRegistry.descriptor(for: .codex).metadata.displayName))

        let profileBSnapshot = Self.snapshot(cost: 2)
        store._setTokenSnapshotForTesting(profileBSnapshot, provider: .codex)

        #expect(section.costStatusText(provider: .codex).contains(Self.formattedCost(2)))
    }

    @Test
    func `Codex ambient cost status remains visible across profile selection`() {
        let (settings, store) = Self.makeCodexFixture(ambient: true)
        let profileA = "/tmp/cost-status-ambient-a"
        let profileB = "/tmp/cost-status-ambient-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let snapshot = Self.snapshot(cost: 3)
        store._setTokenSnapshotForTesting(snapshot, provider: .codex)
        let section = CostSummarySettingsSection(settings: settings, store: store)
        let profileAStatus = section.costStatusText(provider: .codex)

        settings.codexActiveSource = .profileHome(path: profileB)

        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex)?.snapshot == snapshot)
        #expect(section.costStatusText(provider: .codex) == profileAStatus)
    }

    private static func makeCodexFixture(ambient: Bool) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(suiteName: "CostSummarySettingsSectionTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = ambient
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (settings, store)
    }

    private static func snapshot(cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: cost,
            last30DaysTokens: 20,
            last30DaysCostUSD: cost,
            currencyCode: "USD",
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_787_356_800))
    }

    private static func formattedCost(_ cost: Double) -> String {
        UsageFormatter.currencyString(cost, currencyCode: "USD")
    }
}
