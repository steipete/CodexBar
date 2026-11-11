import Testing
@testable import CodexBar
@testable import CodexBarCore

extension ProviderSettingsDescriptorTests {
    @Test
    func `Future AGI keeps both credentials masked and projects them independently`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-futureagi")
        let provider = UsageProvider.futureagi
        let implementation = try #require(ProviderCatalog.implementation(for: provider))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: provider))
        #expect(fields.map(\.kind) == [.secure, .secure])
        fields[0].binding.wrappedValue = "fixture-key"
        fields[1].binding.wrappedValue = "fixture-secret"
        let config = try #require(fixture.settings.providerConfig(for: provider))
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let credentials = try #require(descriptor.credentials)
        let environment = credentials.applyConfig(base: ["FI_SECRET_KEY": "environment-secret"], config: config)
        #expect(environment["FI_API_KEY"] == "fixture-key")
        #expect(environment["FI_SECRET_KEY"] == "fixture-secret")
        #expect(!descriptor.metadata.defaultEnabled)
    }

    @Test
    func `Claude Platform on AWS masks both key parts and projects them with regions`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claudeplatformaws")
        let provider = UsageProvider.claudeplatformaws
        let implementation = try #require(ProviderCatalog.implementation(for: provider))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: provider))
        #expect(fields.map(\.kind) == [.secure, .secure, .plain, .plain, .plain, .plain])
        fields[0].binding.wrappedValue = "FIXTUREKEYID"
        fields[1].binding.wrappedValue = "fixture-secret"
        fields[2].binding.wrappedValue = "us-west-2, us-east-1"
        fields[3].binding.wrappedValue = " 500 "
        fields[4].binding.wrappedValue = "25"
        fields[5].binding.wrappedValue = "utc"
        let config = try #require(fixture.settings.providerConfig(for: provider))
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let credentials = try #require(descriptor.credentials)
        let environment = credentials.applyConfig(
            base: ["ANTHROPIC_AWS_SECRET_ACCESS_KEY": "environment-secret"], config: config)
        #expect(environment["ANTHROPIC_AWS_ACCESS_KEY_ID"] == "FIXTUREKEYID")
        #expect(environment["ANTHROPIC_AWS_MONTHLY_BUDGET"] == "500")
        #expect(environment["ANTHROPIC_AWS_DAILY_BUDGET"] == "25")
        #expect(environment["ANTHROPIC_AWS_TIME_ZONE"] == "utc")
        // Clearing a budget removes it instead of projecting an empty value.
        fields[4].binding.wrappedValue = ""
        let cleared = try #require(fixture.settings.providerConfig(for: provider))
        #expect(credentials.applyConfig(base: [:], config: cleared)["ANTHROPIC_AWS_DAILY_BUDGET"] == nil)
        #expect(environment["ANTHROPIC_AWS_SECRET_ACCESS_KEY"] == "fixture-secret")
        #expect(environment["ANTHROPIC_AWS_REGIONS"] == "us-west-2, us-east-1")
        #expect(descriptor.tokenCost.supportsTokenCost)
        #expect(descriptor.presentation.menuCard.supportsInlineTokenCostDashboard)
        #expect(!descriptor.metadata.defaultEnabled)
    }

    @Test
    func `account API providers keep credentials and project scope separate`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-accountAPIs")
        let providers: [(UsageProvider, String)] = [
            (.cosmic, "COSMIC_TOKEN"), (.aerostack, "AEROSTACK_TOKEN"),
            (.sailresearch, "SAIL_API_KEY"), (.sofya, "SOFYA_API_KEY"),
        ]
        for (provider, environmentKey) in providers {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            let implementation = try #require(ProviderCatalog.implementation(for: provider))
            let fields = implementation.settingsFields(context: fixture.settingsContext(provider: provider))
            #expect(fields.map(\.kind) == (provider == .cosmic ? [.secure, .plain] : [.secure]))
            fields[0].binding.wrappedValue = "fixture-\(provider.rawValue)"
            if provider == .cosmic { fields[1].binding.wrappedValue = "project-fixture" }
            let config = try #require(fixture.settings.providerConfig(for: provider))
            #expect(config.apiKey == "fixture-\(provider.rawValue)")
            let credentials = try #require(descriptor.credentials)
            let environment = credentials.applyConfig(base: [:], config: config)
            #expect(environment[environmentKey] == config.apiKey)
            #expect(environment["COSMIC_PROJECT_ID"] == (provider == .cosmic ? "project-fixture" : nil))
            #expect(credentials.resolveToken(environment: environment)?.token == config.apiKey)
            #expect(credentials.resolveToken(environment: ["UNRELATED_TOKEN": "fixture"])?.token == nil)
            #expect(!descriptor.metadata.defaultEnabled)
            #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        }
    }
}
