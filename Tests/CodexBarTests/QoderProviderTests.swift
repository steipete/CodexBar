import CodexBarCore
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
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-qoder")
        #expect(descriptor.branding.iconStyle == .qoder)
        #expect(!descriptor.metadata.supportsCredits)
        #if os(macOS)
        #expect(descriptor.metadata.browserCookieOrder == [.chrome])
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
