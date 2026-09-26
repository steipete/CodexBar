import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginOptionalAdmissionTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `request admission waits do not spend the optional collection budget`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try ProviderPluginRuntime(
            source: """
            defineProvider({
              id: 'admission-fixture', name: 'Admission fixture', endpoints: ['https://example.test'], settings: [],
              async fetchUsage(ctx) {
                const response = await ctx.http.getWithOptional('https://example.test/primary',
                  'https://example.test/optional');
                return {identity: {loginMethod: response.optional?.bodyText || 'none'}};
              }
            });
            """,
            resourceBundle: CodexBarCoreResources.bundle,
            transport: ProviderHTTPTransportHandler { request in
                if request.url?.path == "/optional" { try await Task.sleep(for: .milliseconds(20)) }
                return try (Data("ready".utf8), #require(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
            },
            allowsDynamicID: true,
            contextOptions: ProviderPluginContextOptions(
                optionalRequestTimeoutSeconds: nil,
                optionalCollectionBudget: .seconds(2),
                beforeHTTPAttempt: { try await Task.sleep(for: .seconds(3)) }),
            engine: engine)
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "ready")
    }
}
