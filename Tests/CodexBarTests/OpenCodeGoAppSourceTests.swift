import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct OpenCodeGoAppSourceTests {
    @Test(arguments: [ProviderSourceMode.auto, .api, .web])
    func `app honors configured source even when manual cookies exist`(source: ProviderSourceMode) async throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(
            suite: "OpenCodeGoAppSourceTests-\(source.rawValue)")
        fixture.settings.updateProviderConfig(provider: .opencodego) { config in
            config.source = source
            config.cookieSource = .manual
            config.cookieHeader = "Cookie: invalid"
            config.apiKey = "fixture-api-key"
        }

        let resolved = ProviderRegistry.resolvedSourceMode(
            provider: .opencodego, settings: fixture.settings, account: nil)
        #expect(resolved == source)
        let spec = try #require(fixture.store.providerSpecs[.opencodego])
        let fetchContext = spec.makeFetchContext()
        #expect(fetchContext.sourceMode == source)
        #expect(fetchContext.settings?.opencodego?.cookieSource == .manual)
        let strategies = await spec.descriptor.fetchPlan.pipeline.resolveStrategies(fetchContext)
        if source == .api {
            #expect(strategies.map(\.id) == ["opencodego.api"])
        } else if source == .web {
            #expect(strategies.map(\.id) == ["opencodego.web"])
        } else {
            #expect(strategies.map(\.id) == ["opencodego.web", "opencodego.local", "opencodego.api"])
        }
    }

    @Test
    func `settings header shows configured or last successful source instead of web`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(
            suite: "OpenCodeGoAppSourceTests-header")
        fixture.settings.updateProviderConfig(provider: .opencodego) { $0.source = .api }
        let context = fixture.presentationContext(
            provider: .opencodego, metadata: OpenCodeGoProviderDescriptor.descriptor.metadata)
        let presentation = OpenCodeGoProviderImplementation().presentation(context: context)

        #expect(presentation.detailLine(context) == "api")
        fixture.store.lastSourceLabels[.opencodego] = "local+api"
        #expect(presentation.detailLine(context) == "local+api")
    }
}
