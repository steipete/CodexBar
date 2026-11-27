import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuDescriptorAntigravityTests {
    @Test
    func `antigravity identity only snapshot shows limits unavailable`() throws {
        let suite = "MenuDescriptorAntigravityTests-unavailable"
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
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "Paid"))
        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        let descriptor = MenuDescriptor.build(
            provider: .antigravity,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let lines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(lines.contains("Limits not available"))
    }

    @Test
    func `antigravity menu does not add unavailable notes for missing families`() throws {
        let suite = "MenuDescriptorAntigravityTests-missing-gemini"
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
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: nil,
                resetsAt: Date().addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))
        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        let descriptor = MenuDescriptor.build(
            provider: .antigravity,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let lines = descriptor.sections
            .flatMap(
                \.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(!lines.contains("Gemini Pro unavailable."))
        #expect(!lines.contains("Gemini Flash unavailable."))
        #expect(!lines.contains("Limits not available"))
    }

    @Test
    func `antigravity descriptor does not render session pace for weekly primary window`() throws {
        let suite = "MenuDescriptorAntigravityTests-weekly-primary-pace"
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
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 80,
                windowMinutes: 10080,
                resetsAt: Date().addingTimeInterval(2 * 24 * 3600),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))
        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        let descriptor = MenuDescriptor.build(
            provider: .antigravity,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let lines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(!lines.contains { $0.hasPrefix("Pace:") })
    }

    @Test
    func `antigravity menu descriptor surfaces usage dashboard only for validated https subscription URI`() throws {
        func hasDashboardAction(manageURI: String?, upgradeURI: String? = nil) throws -> Bool {
            let suite = "MenuDescriptorAntigravityTests-dashboard-\(UUID().uuidString)"
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
            let snapshot = UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                antigravityAccountMetadata: AntigravityAccountMetadata(
                    manageSubscriptionURI: manageURI,
                    upgradeSubscriptionURI: upgradeURI),
                updatedAt: Date())
            store._setSnapshotForTesting(snapshot, provider: .antigravity)

            let descriptor = MenuDescriptor.build(
                provider: .antigravity,
                store: store,
                settings: settings,
                account: AccountInfo(email: nil, plan: nil),
                updateReady: false,
                includeContextualActions: true)
            return descriptor.sections
                .flatMap(\.entries)
                .contains { entry in
                    if case .action(_, .dashboard) = entry { return true }
                    return false
                }
        }

        #expect(try hasDashboardAction(manageURI: "https://one.google.com/subscriptions"))
        #expect(try hasDashboardAction(manageURI: nil, upgradeURI: "https://one.google.com/upgrade"))
        #expect(try !hasDashboardAction(manageURI: nil, upgradeURI: nil))
        #expect(try !hasDashboardAction(manageURI: "http://one.google.com/insecure"))
        #expect(try !hasDashboardAction(manageURI: "javascript:alert(1)"))
        #expect(try !hasDashboardAction(manageURI: "https://:443/path"))
        #expect(try !hasDashboardAction(manageURI: "https://user@/path"))
    }
}
