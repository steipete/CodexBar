import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct MuseAIProviderTests {
    @Test(arguments: [ProviderSourceMode.auto, .web])
    func `manual cookies work without platform browser support`(mode: ProviderSourceMode) {
        let settings = ProviderSettingsSnapshot(
            CookieProviderSettings(cookieSource: .manual, manualCookieHeader: "hatch_sess=fixture"),
            for: MuseAIProviderSettingsKey.self)
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(mode, provider: .museai, settings: settings))
        for source in [ProviderCookieSource.auto, .off] {
            let settings = ProviderSettingsSnapshot(
                CookieProviderSettings(cookieSource: source), for: MuseAIProviderSettingsKey.self)
            #expect(CodexBarCLI.sourceModeRequiresWebSupport(mode, provider: .museai, settings: settings))
        }
    }

    @Test
    func `identity and browser scope are distinct from Muse Code`() {
        let descriptor = MuseAIProviderDescriptor.descriptor
        #expect(descriptor.metadata.displayName == "Muse (muse.ai)")
        #expect(descriptor.metadata.dashboardURL == "https://muse.ai/?settings_tab=general")
        #expect(descriptor.metadata.browserCookieOrder == nil)
        #expect(MuseProviderDescriptor.descriptor.metadata.displayName == "Muse Code")
    }
}
