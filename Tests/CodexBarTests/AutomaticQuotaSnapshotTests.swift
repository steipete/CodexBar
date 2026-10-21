import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AutomaticQuotaSnapshotTests {
    @Test
    func `automatic uses a busy weekly quota instead of an empty session`() {
        let snapshot = UsageSnapshot(
            primary: Self.window(used: 0, minutes: 300),
            secondary: Self.window(used: 90, minutes: 10080),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let selected = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: .claude, snapshot: snapshot, supportsAverage: false)

        #expect(selected == snapshot.secondary)
    }

    @Test
    func `highest usage follows the quota projected to deplete before reset`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = testSettingsStore(
            suiteName: "AutomaticQuotaSnapshotTests",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }))
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        for provider in [UsageProvider.claude, .gemini] {
            let metadata = try #require(ProviderRegistry.shared.metadata[provider])
            settings.setProviderEnabled(
                provider: provider, metadata: metadata, enabled: true)
            settings.setMenuBarMetricPreference(.automatic, for: provider)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(
                homeDirectory: "/synthetic-auto-quota",
                cacheTTL: 0,
                now: { now },
                fileExists: { _ in false },
                directoryContents: { _ in [] },
                applicationURLs: { _ in [] },
                profileAccessIssue: { _ in nil }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: Self.window(used: 0, minutes: 300),
                secondary: Self.window(used: 60, minutes: 10080, reset: now.addingTimeInterval(6 * 86400)),
                updatedAt: now),
            provider: .claude)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: Self.window(used: 80, minutes: 1440, reset: now.addingTimeInterval(2 * 3600)),
                secondary: nil,
                updatedAt: now),
            provider: .gemini)

        let highest = store.providerWithHighestUsage(candidateProviders: [.claude, .gemini], now: now)

        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 60)

        settings.setMenuBarMetricPreference(.primary, for: .claude)
        settings.setMenuBarMetricPreference(.primary, for: .gemini)
        let explicit = store.providerWithHighestUsage(candidateProviders: [.claude, .gemini], now: now)
        #expect(explicit?.provider == .gemini)
        #expect(explicit?.usedPercent == 80)
    }

    private static func window(used: Double, minutes: Int, reset: Date? = nil) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: reset, resetDescription: nil)
    }
}
