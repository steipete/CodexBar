import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct VercelProviderSettingsTests {
    @Test
    func `missing personal budget message is localized as a detail label`() throws {
        let label = "No personal budget configured"
        let details = try [ProviderDetailSection(title: "Personal budget", rows: [.init(label: label, value: "—")])]
        for language in AppLanguage.allCases where language != .system && language != .english {
            CodexBarLocalizationOverride.$appLanguage.withValue(language.rawValue) {
                let localized = UsageMenuCardView.Model.localizedProviderDetails(details, provider: .vercel)
                #expect(localized.first?.rows.first?.label != label)
                #expect(localized.first?.rows.first?.value == "—")
            }
        }
    }

    @Test
    func `Vercel keeps the gateway key, access token, and team in provider config`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        let fields = try #require(ProviderCatalog.implementation(for: .vercel))
            .settingsFields(context: fixture.settingsContext(provider: .vercel))
        #expect(fields.map(\.id) == ["vercel-api-key", "vercel-access-token", "vercel-team-id"])
        #expect(fields.map(\.kind) == [.secure, .secure, .plain])
        fields[0].binding.wrappedValue = "fixture-key"
        fields[1].binding.wrappedValue = "fixture-token"
        fields[2].binding.wrappedValue = "team_fixture"
        let config = try #require(fixture.settings.providerConfig(for: .vercel))
        #expect(config.apiKey == "fixture-key")
        #expect(config.pluginSecrets?["VERCEL_ACCESS_TOKEN"] == "fixture-token")
        #expect(config.workspaceID == "team_fixture")
        let environment = try #require(VercelProviderDescriptor.descriptor.credentials)
            .applyConfig(base: [:], config: config)
        #expect(environment["VERCEL_ACCESS_TOKEN"] == "fixture-token")
        #expect(environment["VERCEL_TEAM_ID"] == "team_fixture")
    }
}
