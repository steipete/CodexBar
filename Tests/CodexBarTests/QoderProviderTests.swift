import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct QoderProviderTests {
    @Test
    func `descriptor metadata is correct`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .qoder)

        #expect(descriptor.metadata.displayName == "Qoder")
        #expect(descriptor.metadata.dashboardURL == QoderWebSite.international.dashboardURL.absoluteString)
        #expect(QoderWebSite.international.dashboardURL.absoluteString == "https://qoder.com/account/usage")
        #expect(QoderWebSite.china.dashboardURL.absoluteString == "https://qoder.com.cn/account/usage")
        #expect(descriptor.metadata.cliName == "qoder")
        #expect(descriptor.metadata.sessionLabel == "Credits")
        #expect(descriptor.metadata.weeklyLabel == "Add-on credits")
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-qoder")
        #expect(descriptor.branding.iconStyle == .qoder)
        #expect(!descriptor.metadata.supportsCredits)
        #if os(macOS)
        #expect(descriptor.metadata.browserCookieOrder == ProviderBrowserCookieDefaults.defaultImportOrder)
        #else
        #expect(descriptor.metadata.browserCookieOrder == nil)
        #endif
    }

    @MainActor
    @Test
    func `implementation is registered`() {
        #expect(ProviderCatalog.implementation(for: .qoder) != nil)
    }

    @Test
    func `dynamic labels distinguish plan organization and aggregate credits`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .qoder)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "0 / 0 credits",
                title: "Plan credits"),
            secondary: RateWindow(
                usedPercent: 24,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "1,200 / 5,000 credits",
                title: "Organization resource package"),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .qoder,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
        let planLabels = descriptor.presentation.rateWindowLabels(metadata: descriptor.metadata, snapshot: plan)
        #expect(planLabels.primary == "Plan credits")
        #expect(planLabels.secondary == "Organization resource package")

        let legacy = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 68,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "1,700 / 2,500 credits",
                title: "Credits"),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .qoder,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
        let legacyLabels = descriptor.presentation.rateWindowLabels(metadata: descriptor.metadata, snapshot: legacy)
        #expect(legacyLabels.primary == "Credits")
    }

    @Test
    func `semantic weekly label stays neutral for credit pools`() {
        #expect(PercentWindow.weekly.providerLabel(provider: .qoder) == "Credits")
    }

    @Test
    func `dashboard URL follows manual header classifier`() {
        let global = ProviderSettingsSnapshot.QoderProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "sid=abc")
        let china = ProviderSettingsSnapshot.QoderProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "curl https://qoder.com.cn -H 'Cookie: sid=abc'")
        let malformed = ProviderSettingsSnapshot.QoderProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "curl https://qoder.com -H 'Host: qoder.com.cn' -H 'Cookie: sid=abc'")

        #expect(QoderProviderDescriptor.dashboardURL(settings: global, sourceLabel: "manual / qoder.com.cn") ==
            QoderWebSite.international.dashboardURL)
        #expect(QoderProviderDescriptor.dashboardURL(settings: china, sourceLabel: "manual / qoder.com") ==
            QoderWebSite.china.dashboardURL)
        #expect(QoderProviderDescriptor.dashboardURL(settings: malformed, sourceLabel: "manual / qoder.com.cn") ==
            QoderWebSite.international.dashboardURL)
    }

    @Test
    func `dashboard URL follows resolved source labels outside manual mode`() {
        let automatic = ProviderSettingsSnapshot.QoderProviderSettings(cookieSource: .auto, manualCookieHeader: nil)

        #expect(QoderProviderDescriptor.dashboardURL(settings: automatic, sourceLabel: "Chrome / qoder.com.cn") ==
            QoderWebSite.china.dashboardURL)
        #expect(QoderProviderDescriptor.dashboardURL(settings: automatic, sourceLabel: "Chrome / qoder.com") ==
            QoderWebSite.international.dashboardURL)
        #expect(QoderProviderDescriptor.dashboardURL(settings: automatic, sourceLabel: nil) ==
            QoderWebSite.international.dashboardURL)
    }
}
