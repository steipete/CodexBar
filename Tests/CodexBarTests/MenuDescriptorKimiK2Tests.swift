import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuDescriptorKimiK2Tests {
    @Test
    func `kimi K2 menu exposes the usage dashboard action`() {
        let settings = testSettingsStore(suiteName: "MenuDescriptorKimiK2Tests-dashboard")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
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
    }
}
