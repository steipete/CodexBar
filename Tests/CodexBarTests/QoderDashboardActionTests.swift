import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct QoderDashboardActionTests {
    private func makeSettings() -> SettingsStore {
        let suite = "QoderDashboardActionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        return settings
    }

    private func makeStore(settings: SettingsStore) -> UsageStore {
        let fetcher = UsageFetcher()
        return UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
    }

    private func makeContext(settings: SettingsStore, store: UsageStore) -> ProviderSettingsContext {
        ProviderSettingsContext(
            provider: .qoder,
            settings: settings,
            store: store,
            boolBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            stringBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in },
            runLoginFlow: {})
    }

    @Test
    func `qoder dashboard action follows current manual header`() {
        let settings = self.makeSettings()
        settings.qoderCookieSource = .manual
        settings.qoderCookieHeader = "curl https://qoder.com.cn -H 'Cookie: sid=abc'"
        let store = self.makeStore(settings: settings)
        let context = self.makeContext(settings: settings, store: store)
        let fields = QoderProviderImplementation().settingsFields(context: context)
        let action = fields.first { $0.id == "qoder-cookie" }?.actions.first { $0.id == "qoder-open-usage" }

        #expect(action != nil)
        #expect(QoderProviderImplementation.usageDashboardURL(settings: settings) == QoderWebSite.china.dashboardURL)
        #expect(QoderProviderDescriptor.dashboardURL(
            settings: settings.qoderSettingsSnapshot(tokenOverride: nil),
            sourceLabel: "manual / qoder.com") == QoderWebSite.china.dashboardURL)

        settings.qoderCookieHeader = "curl https://qoder.com -H 'Host: qoder.com.cn' -H 'Cookie: sid=abc'"
        #expect(QoderProviderImplementation.usageDashboardURL(settings: settings) ==
            QoderWebSite.international.dashboardURL)

        settings.qoderCookieHeader = "curl https://qoder.com -H 'Cookie: sid=abc'"
        #expect(QoderProviderImplementation.usageDashboardURL(settings: settings) ==
            QoderWebSite.international.dashboardURL)
    }

    @Test
    func `qoder dashboard route trusts generated source label suffix only`() {
        let automatic = ProviderSettingsSnapshot.QoderProviderSettings(cookieSource: .auto, manualCookieHeader: nil)

        #expect(QoderProviderDescriptor.dashboardURL(
            settings: automatic,
            sourceLabel: "Chrome Profile qoder.com.cn / qoder.com") == QoderWebSite.international.dashboardURL)
        #expect(QoderProviderDescriptor.dashboardURL(
            settings: automatic,
            sourceLabel: "Chrome Profile qoder.com / qoder.com.cn") == QoderWebSite.china.dashboardURL)
        #expect(QoderProviderDescriptor.dashboardURL(
            settings: automatic,
            sourceLabel: "Chrome Profile qoder.com.cn") == QoderWebSite.international.dashboardURL)
        #expect(QoderProviderDescriptor.dashboardURL(
            settings: automatic,
            sourceLabel: "Chrome Profile / qoder.com.cn/extra") == QoderWebSite.international.dashboardURL)
    }
}
