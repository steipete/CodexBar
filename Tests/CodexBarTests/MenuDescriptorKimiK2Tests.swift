import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorKimiK2Tests {
    @Test
    func `kimi K2 menu exposes the usage dashboard action`() throws {
        let suite = "MenuDescriptorKimiK2Tests-dashboard"
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

        let descriptor = MenuDescriptor.build(
            provider: .kimik2,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false)
        let actions = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> (String, MenuDescriptor.MenuAction)? in
                guard case let .action(title, action) = entry else { return nil }
                return (title, action)
            }

        #expect(actions.contains { title, action in
            title == "Usage Dashboard" && action == .dashboard
        })
        #expect(
            store.metadata(for: .kimik2).dashboardURL == "https://kimrel.com/my-credits",
            "Dashboard action must open the human-facing credits page, not the bearer-token API endpoint")
    }
}