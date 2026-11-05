import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct SiliconFlowProviderTests {
    @Test
    func `API key and official origin use the standard settings fields`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "SiliconFlowProviderTests")
        let implementation = try #require(ProviderCatalog.implementation(for: .siliconflow))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .siliconflow))
        #expect(fields.map(\.kind) == [.secure, .plain])
        #expect(fields.map(\.title) == ["API key", "API URL"])
        #expect(ProviderSelection(argument: "SILICONFLOW")?.asList == [.siliconflow])
        #expect(!implementation.isAvailable(context: .init(
            provider: .siliconflow, settings: fixture.settings, environment: [:])))
        fields[0].binding.wrappedValue = "sk-fixture"
        #expect(fixture.settings[providerConfig: .siliconflow, field: .apiKey] == "sk-fixture")
        #expect(implementation.isAvailable(context: .init(
            provider: .siliconflow, settings: fixture.settings, environment: [:])))

        let descriptor = SiliconFlowProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        let environment = credentials.applyConfig(
            base: ["SILICONFLOW_API_KEY": "environment-fixture"],
            config: ProviderConfig(
                id: .siliconflow,
                apiKey: "sk-fixture",
                enterpriseHost: "https://api.siliconflow.com/v1/"))
        #expect(environment["SILICONFLOW_API_KEY"] == "sk-fixture")
        #expect(environment["SILICONFLOW_BASE_URL"] == "https://api.siliconflow.com/v1/")
        #expect(credentials.resolveToken(environment: environment)?.token == "sk-fixture")
        #expect(descriptor.metadata.balanceOnly)
        #expect(!descriptor.metadata.burnDownWidgetSelectable)
        #expect(descriptor.history == .unavailable)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        let issues = credentials.validateConfig(ProviderConfig(
            id: .siliconflow,
            enterpriseHost: "https://example.com"))
        #expect(issues.map(\.code) == ["siliconflow_api_origin_invalid"])
    }

    @Test
    func `origin defaults to China and rejects every other host`() throws {
        #expect(SiliconFlowSettingsReader.baseURL(environment: [:]) == SiliconFlowSettingsReader.chinaOrigin)
        #expect(SiliconFlowSettingsReader.normalizedOrigin("api.siliconflow.cn/v1") ==
            SiliconFlowSettingsReader.chinaOrigin)
        #expect(SiliconFlowSettingsReader.normalizedOrigin("https://api.siliconflow.com/v1/") ==
            SiliconFlowSettingsReader.internationalOrigin)
        for raw in [
            "http://api.siliconflow.cn",
            "https://user:secret@api.siliconflow.cn",
            "https://api.siliconflow.cn.evil.com",
            "https://api.siliconflow.cn/v1/user/info",
            "https://api.siliconflow.cn?q=1",
            "https://api.siliconflow.cn#frag",
            "https://api.siliconflow.cn:443",
        ] {
            #expect(SiliconFlowSettingsReader.normalizedOrigin(raw) == nil, "accepted \(raw)")
        }
        #expect(throws: ProviderFetchClassifiedError.self) {
            try SiliconFlowSettingsReader.validate(environment: ["SILICONFLOW_BASE_URL": "https://example.com"])
        }
    }
}

extension SiliconFlowProviderTests {
    @Test
    func `console links follow validated regional config before environment`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "SiliconFlowRegionalLinks")
        let env = ["SILICONFLOW_BASE_URL": "https://api.siliconflow.com/v1/"]
        #expect(SiliconFlowProviderImplementation.dashboardURL(
            settings: fixture.settings, environment: [:])?.absoluteString == "https://cloud.siliconflow.cn")
        #expect(SiliconFlowProviderImplementation.dashboardURL(
            settings: fixture.settings, environment: env)?.absoluteString == "https://cloud.siliconflow.com")
        fixture.settings[providerConfig: .siliconflow, field: .endpoint] = "https://api.siliconflow.cn/v1"
        #expect(SiliconFlowProviderImplementation.dashboardURL(
            settings: fixture.settings, environment: env)?.absoluteString == "https://cloud.siliconflow.cn")
        fixture.settings[providerConfig: .siliconflow, field: .endpoint] = "https://untrusted.example"
        #expect(SiliconFlowProviderImplementation.dashboardURL(settings: fixture.settings, environment: env) == nil)
        let implementation = try #require(ProviderCatalog.implementation(for: .siliconflow))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .siliconflow))
        #expect(fields[0].actions.isEmpty)
    }
}

extension SiliconFlowProviderTests {
    @Test
    func `diagnostic messages have app translations`() {
        for message in SiliconFlowProviderDescriptor.diagnosticMessages {
            #expect(L(message, language: "it") != message)
        }
        #expect(L("Show SiliconFlow usage", language: "de") == "Nutzung von SiliconFlow anzeigen")
    }
}
