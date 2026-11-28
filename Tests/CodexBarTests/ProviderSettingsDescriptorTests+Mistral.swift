import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension ProviderSettingsDescriptorTests {
    @Test
    func `mistral automatic cookie source exposes validated refresh action`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-mistral-refresh")
        let context = fixture.settingsContext(provider: .mistral)
        let picker = try #require(MistralProviderImplementation().settingsPickers(context: context)
            .first { $0.id == "mistral-cookie-source" })
        let action = try #require(picker.trailingActions.first)
        #expect(action.id == "mistral-reimport-cookie")
        #expect(action.isVisible?() == true)
        fixture.settings.mistralCookieSource = .manual
        #expect(action.isVisible?() == false)
        fixture.settings.mistralCookieSource = .off
        #expect(action.isVisible?() == false)
    }

    @Test
    func `mistral refresh action hides while a saved session owns the request`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-mistral-refresh-account")
        let context = fixture.settingsContext(provider: .mistral)
        let picker = try #require(MistralProviderImplementation().settingsPickers(context: context)
            .first { $0.id == "mistral-cookie-source" })
        let action = try #require(picker.trailingActions.first)

        fixture.settings.addTokenAccount(
            provider: .mistral,
            label: "Work",
            token: "ory_session_test=account-cookie")
        let account = try #require(fixture.settings.selectedTokenAccount(for: .mistral))
        #expect(fixture.settings.mistralCookieSource == .manual)
        #expect(action.isVisible?() == false)

        // Switching the picker back to Automatic does not make the saved session passive, so the
        // browser re-import action must stay hidden while that account still supplies the header.
        fixture.settings.mistralCookieSource = .auto
        #expect(action.isVisible?() == false)
        #expect(fixture.settings.effectiveSelectedTokenAccount(for: .mistral)?.id == account.id)

        fixture.settings.removeTokenAccount(provider: .mistral, accountID: account.id)
        #expect(action.isVisible?() == true)
    }

    @Test
    func `mistral configured usage source reaches the app fetch context`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-mistral-source")
        fixture.settings.mistralAPIKey = "synthetic-key"
        let context = fixture.settingsContext(provider: .mistral)
        let implementation = MistralProviderImplementation()
        let picker = try #require(implementation.settingsPickers(context: context)
            .first { $0.id == "mistral-usage-source" })
        #expect(picker.options.map(\.id) == ["auto", "api", "web"])
        #expect(fixture.store.makeFetchContext(provider: .mistral, override: nil).sourceMode == .auto)

        picker.binding.wrappedValue = "web"
        #expect(fixture.settings.providerConfig(for: .mistral)?.source == .web)
        #expect(fixture.store.makeFetchContext(provider: .mistral, override: nil).sourceMode == .web)

        picker.binding.wrappedValue = "api"
        #expect(fixture.settings.providerConfig(for: .mistral)?.source == .api)
        #expect(fixture.store.makeFetchContext(provider: .mistral, override: nil).sourceMode == .api)
        let cookiePicker = try #require(implementation.settingsPickers(context: context)
            .first { $0.id == "mistral-cookie-source" })
        #expect(cookiePicker.isVisible?() == false)

        picker.binding.wrappedValue = "auto"
        #expect(fixture.store.makeFetchContext(provider: .mistral, override: nil).sourceMode == .auto)
        #expect(cookiePicker.isVisible?() == true)
    }

    @Test
    func `mistral unsupported configured source normalizes to auto`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-mistral-unsupported-source")
        let context = fixture.settingsContext(provider: .mistral)
        let implementation = MistralProviderImplementation()
        let picker = try #require(implementation.settingsPickers(context: context)
            .first { $0.id == "mistral-usage-source" })

        for unsupported in [ProviderSourceMode.cli, .oauth] {
            fixture.settings.updateProviderConfig(provider: .mistral) { $0.source = unsupported }
            #expect(fixture.store.makeFetchContext(provider: .mistral, override: nil).sourceMode == .auto)
            #expect(picker.binding.wrappedValue == "auto")
            #expect(fixture.store.sourceLabel(for: .mistral) == "auto")
        }
    }

    @Test
    func `mistral api mode keeps saved cookie token account passive and auto resumes web`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-mistral-token-account-api")
        fixture.settings.mistralAPIKey = "synthetic-key"
        fixture.settings.addTokenAccount(
            provider: .mistral,
            label: "Work",
            token: "ory_session_test=account-cookie")

        fixture.settings.updateProviderConfig(provider: .mistral) { $0.source = .api }
        #expect(fixture.settings.effectiveSelectedTokenAccount(for: .mistral) == nil)
        let apiFetch = fixture.store.makeFetchContext(provider: .mistral, override: nil)
        #expect(apiFetch.sourceMode == .api)
        #expect(apiFetch.env["MISTRAL_API_KEY"] == "synthetic-key")
        #expect(apiFetch.settings?.mistral?.manualCookieHeader != "ory_session_test=account-cookie")

        fixture.settings.updateProviderConfig(provider: .mistral) { $0.source = .auto }
        #expect(fixture.settings.effectiveSelectedTokenAccount(for: .mistral)?.label == "Work")
        let autoFetch = fixture.store.makeFetchContext(provider: .mistral, override: nil)
        #expect(autoFetch.sourceMode == .web)
        #expect(autoFetch.env["MISTRAL_API_KEY"] == nil)
        #expect(autoFetch.settings?.mistral?.cookieSource == .manual)
        #expect(autoFetch.settings?.mistral?.manualCookieHeader == "ory_session_test=account-cookie")
    }

    @Test
    func `mistral disabled cookie source keeps a saved session passive`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-mistral-token-account-off")
        fixture.settings.mistralAPIKey = "synthetic-key"
        fixture.settings.addTokenAccount(
            provider: .mistral,
            label: "Work",
            token: "ory_session_test=account-cookie")
        fixture.settings.updateProviderConfig(provider: .mistral) { $0.source = .auto }
        #expect(fixture.store.makeFetchContext(provider: .mistral, override: nil).sourceMode == .web)

        fixture.settings.mistralCookieSource = .off

        // Settings says Mistral cookies are disabled, so no saved header may be sent and the account
        // must stop forcing the browser source (and the API key must stay in the request).
        #expect(fixture.settings.effectiveSelectedTokenAccount(for: .mistral) == nil)
        #expect(fixture.settings.selectedTokenAccount(for: .mistral)?.label == "Work")
        let fetch = fixture.store.makeFetchContext(provider: .mistral, override: nil)
        #expect(fetch.sourceMode == .auto)
        #expect(fetch.env["MISTRAL_API_KEY"] == "synthetic-key")
        #expect(fetch.settings?.mistral?.cookieSource == .off)
        // An unset provider field reads as an empty string rather than nil; what matters is that the
        // saved session's cookie is not injected.
        #expect(fetch.settings?.mistral?.manualCookieHeader?.isEmpty == true)
    }

    @Test
    func `mistral cookie refresh uses browser only for that request even with a key`() async throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-mistral-web-refresh")
        fixture.settings.mistralAPIKey = "synthetic-key"
        let context = fixture.settingsContext(provider: .mistral)
        let picker = try #require(MistralProviderImplementation().settingsPickers(context: context)
            .first { $0.id == "mistral-cookie-source" })
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
