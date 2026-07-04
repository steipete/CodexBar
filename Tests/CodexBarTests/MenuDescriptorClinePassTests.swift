import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorClinePassTests {
    @Test
    func `clinepass provider contributes windows plan and account`() throws {
        let lines = try Self.menuLines(email: "dev@example.com", suite: "MenuDescriptorClinePassTests-windows")

        // Plan name is surfaced (not a bogus "Balance" row); the three usage
        // windows render through the shared session/weekly/tertiary rows.
        #expect(lines.contains("Plan: Cline Pass (Monthly)"))
        #expect(lines.contains("Account: dev@example.com"))
        #expect(!lines.contains(where: { $0.contains("Balance:") }))
        // A percentage from at least one window is present somewhere.
        #expect(lines.contains(where: { $0.contains("%") }))
    }

    private static func menuLines(email: String?, suite: String) throws -> [String] {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_739_841_600)
        let usage = ClinePassUsageFetcher.makeSnapshot(
            planName: "Cline Pass (Monthly)",
            accountEmail: email,
            limits: [
                (type: "five_hour", percentUsed: 4, resetsAt: nil),
                (type: "weekly", percentUsed: 6, resetsAt: nil),
                (type: "monthly", percentUsed: 3, resetsAt: nil),
            ],
            now: now)
        store._setSnapshotForTesting(usage.toUsageSnapshot(), provider: .clinepass)

        let descriptor = MenuDescriptor.build(
            provider: .clinepass,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        return descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }
    }
}
