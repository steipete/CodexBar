import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HelmcodeProviderSettingsTests {
    @Test @MainActor
    func `manual tenant and cookie settings survive app and CLI projection`() throws {
        let settings = testSettingsStore(
            suiteName: "HelmcodeProviderSettingsTests",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        settings.helmcodeCookieSource = .manual
        settings.helmcodeCookieHeader = "session=fixture"
        settings.helmcodeManualTenant = "nanBuilders"
        let config = try #require(settings.providerConfig(for: .helmcode))
        let contribution = try #require(HelmcodeProviderDescriptor.descriptor.settingsSection.credentialContribution(
            context: ProviderCredentialSettingsContext(config: config, account: nil)))
        let projected =
            try #require(ProviderSettingsSnapshot(contributions: [contribution])[HelmcodeProviderSettingsKey.self])
        #expect(projected.cookieSource == .manual)
        #expect(projected.manualCookieHeader == "session=fixture")
        #expect(projected.manualTenant == "nanBuilders")
        #expect(ProviderCatalog.implementation(for: .helmcode) is HelmcodeProviderImplementation)
    }
}
