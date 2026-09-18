import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorUpdateAndVersionTests {
    @Test
    func `metaSection includes check for updates when updater is available`() {
        let descriptor = MenuDescriptor.build(
            provider: nil,
            store: self.makeStore(),
            settings: self.makeSettings(),
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            canCheckForUpdates: true,
            versionText: "v1.2.3")

        let actions = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> (label: String, action: MenuDescriptor.MenuAction)? in
                guard case let .action(label, action) = entry else { return nil }
                return (label, action)
            }

        #expect(actions.contains(where: { $0.action == .checkForUpdates }))
        #expect(actions.contains(where: { $0.action == .about && $0.label.contains("v1.2.3") }))
    }

    @Test
    func `metaSection prioritizes install update when update is ready`() {
        let descriptor = MenuDescriptor.build(
            provider: nil,
            store: self.makeStore(),
            settings: self.makeSettings(),
            account: AccountInfo(email: nil, plan: nil),
            updateReady: true,
            canCheckForUpdates: true,
            versionText: "v1.2.3")

        let actions = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> (label: String, action: MenuDescriptor.MenuAction)? in
                guard case let .action(label, action) = entry else { return nil }
                return (label, action)
            }

        #expect(actions.contains(where: { $0.action == .installUpdate }))
        #expect(!actions.contains(where: { $0.action == .checkForUpdates }))
    }

    private func makeSettings() -> SettingsStore {
        let suite = "MenuDescriptorUpdateAndVersionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeStore() -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: self.makeSettings())
    }
}
