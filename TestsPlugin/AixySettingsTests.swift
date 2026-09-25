import Foundation
import Testing
@testable import CodexBarCore

struct AixySettingsTests {
    @Test
    func `settings default to Aixy and reject unsafe endpoint overrides`() {
        #expect(AixySettingsReader.apiKey(environment: ["AIXY_API_KEY": " 'gak_fixture' "]) == "gak_fixture")
        #expect(AixySettingsReader.baseURL(environment: [:])?.absoluteString == "https://api.aixy-gateway.com")
        for endpoint in [
            "https://aixy.example.com/v1",
            "http://localhost:8080",
            "http://192.168.1.2:8080",
            "http://gateway.local:8080",
        ] {
            #expect(AixySettingsReader.baseURL(environment: ["AIXY_BASE_URL": endpoint]) != nil)
        }
        for endpoint in [
            "http://aixy.example.com",
            "https://user:password@aixy.example.com",
            "https://aixy.example.com?key=secret",
            "https://aixy.example.com/#fragment",
            "file:///fixture",
        ] {
            #expect(AixySettingsReader.baseURL(environment: ["AIXY_BASE_URL": endpoint]) == nil)
        }
    }

    @Test
    func `API strategy needs only a key and preserves invalid host diagnostics`() async {
        let descriptor = AixyProviderDescriptor.descriptor
        for (environment, available) in [
            ([:], false), (["AIXY_API_KEY": "gak_fixture"], true),
            (["AIXY_BASE_URL": "https://aixy.example.com"], false),
            (["AIXY_API_KEY": "gak_fixture", "AIXY_BASE_URL": "http://public.example.com"], true),
        ] {
            let context = ProviderFetchContext(
                runtime: .cli,
                sourceMode: .api,
                includeCredits: false,
                webTimeout: 1,
                webDebugDumpHTML: false,
                verbose: false,
                env: environment,
                settings: nil,
                fetcher: UsageFetcher(environment: environment),
                claudeFetcher: AixyUnusedClaudeFetcher(),
                browserDetection: BrowserDetection(
                    homeDirectory: "/nonexistent/aixy-fixture",
                    fileExists: { _ in false },
                    directoryContents: { _ in nil }))
            let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
            #expect(strategies.map(\.id) == ["aixy.js"])
            #expect(await strategies[0].isAvailable(context) == available)
        }
    }

    @Test(arguments: AixyPluginTests.engines)
    func `unsafe origins never reach the transport`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try AixyPluginTests.runtime(
            "aixy",
            engine: engine,
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("Unsafe endpoint reached the transport")
                throw URLError(.badURL)
            })
        for base in [
            "http://public.example.com",
            "https://user:password@aixy.example.com",
            "https://aixy.example.com?secret=value",
            "https://aixy.example.com/#fragment",
        ] {
            await #expect(throws: (any Error).self) {
                try await runtime.fetchUsage(
                    settings: ["AIXY_BASE_URL": base],
                    secrets: ["AIXY_API_KEY": "gak_fixture"])
            }
        }
    }
}

private struct AixyUnusedClaudeFetcher: ClaudeUsageFetching {
    func detectVersion() -> String? { nil }
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot { throw CancellationError() }
    func debugRawProbe(model _: String) async -> String { "unused" }
}
