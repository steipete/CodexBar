import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension ProviderSettingsDescriptorTests {
    @Test
    func `mistral automatic cookie source exposes validated refresh action`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-mistral-refresh")
        let context = fixture.settingsContext(provider: .mistral)
        let picker = try #require(MistralProviderImplementation().settingsPickers(context: context).first)
        let action = try #require(picker.trailingActions.first)
        #expect(action.id == "mistral-reimport-cookie")
        #expect(action.isVisible?() == true)
        fixture.settings.mistralCookieSource = .manual
        #expect(action.isVisible?() == false)
        fixture.settings.mistralCookieSource = .off
        #expect(action.isVisible?() == false)
    }

    @Test
    func `mistral cookie refresh uses browser only for that request even with a key`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-mistral-web-refresh")
        fixture.settings.mistralAPIKey = "synthetic-key"
        let context = fixture.settingsContext(provider: .mistral)
        let picker = try #require(MistralProviderImplementation().settingsPickers(context: context).first)
        let action = try #require(picker.trailingActions.first)
        let service = "com.steipete.codexbar.tests.settings-cookie-refresh.\(UUID().uuidString)"
        var observedMode: ProviderSourceMode?
        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                fixture.store._test_providerRefreshOverride = { provider in
                    let fetch = fixture.store.makeFetchContext(provider: provider, override: nil)
                    observedMode = fetch.sourceMode
                    #expect(fetch.env["MISTRAL_API_KEY"] == "synthetic-key")
                    #expect(fixture.store.makeFetchContext(provider: .opencode, override: nil).sourceMode == .auto)
                    fixture.store.snapshots[provider.instanceID] = UsageSnapshot(
                        primary: nil, secondary: nil, updatedAt: Date())
                    fixture.store.lastSourceLabels[provider.instanceID] = "web"
                }
                defer { fixture.store._test_providerRefreshOverride = nil }
                await action.perform()
            }
        }
        #expect(observedMode == .web)
        #expect(fixture.store.makeFetchContext(provider: .mistral, override: nil).sourceMode == .auto)
    }
}
