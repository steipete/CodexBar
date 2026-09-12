import Foundation
import Testing
@testable import CodexBarCore

private struct NousStubClaudeFetcher: ClaudeUsageFetching {
    struct Unavailable: Error {}
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot { throw Unavailable() }
    func debugRawProbe(model _: String) async -> String { "stub" }
    func detectVersion() -> String? { nil }
}

struct NousProviderDescriptorTests {
    @Test
    func `descriptor exposes api source and hermes aliases`() {
        let descriptor = NousProviderDescriptor.descriptor
        #expect(descriptor.id == .nous)
        #expect(descriptor.metadata.supportsCredits)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.cli.aliases == ["nous-portal", "hermes"])
        #expect(descriptor.metadata.dashboardURL == "https://portal.nousresearch.com/usage")
    }

    @Test
    func `credential adapter resolves environment token without config`() {
        let credentials = NousProviderDescriptor.descriptor.credentials
        let resolution = credentials?.resolveToken(environment: [
            "HOME": "/nonexistent",
            "NOUS_PORTAL_ACCESS_TOKEN": "env-token",
        ])
        #expect(resolution?.token == "env-token")
        #expect(resolution?.source == .environment)
        #expect(credentials?.resolveToken(environment: ["HOME": "/nonexistent"]) == nil)
        #expect(credentials?.unavailableMessage(environment: ["HOME": "/nonexistent"])?.contains("hermes") == true)
    }

    @Test
    func `strategy is unavailable without a credential`() async {
        let strategy = NousAPIFetchStrategy()
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .api,
            includeCredits: true,
            webTimeout: 5,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["HOME": "/nonexistent"],
            settings: nil,
            fetcher: UsageFetcher(environment: ["HOME": "/nonexistent"]),
            claudeFetcher: NousStubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
        #expect(await strategy.isAvailable(context) == false)
    }

    @Test
    func `strategy stays available with an expired environment token so the fetch reports why`() async {
        let header = Data("{\"alg\":\"none\"}".utf8).base64EncodedString()
        let payload = Data("{\"exp\": 946684800}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let env = ["HOME": "/nonexistent", "NOUS_PORTAL_ACCESS_TOKEN": "\(header).\(payload).sig"]
        let strategy = NousAPIFetchStrategy()
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 5,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: NousStubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
        #expect(await strategy.isAvailable(context))
        await #expect(throws: NousUsageError.environmentTokenExpired) {
            _ = try await strategy.fetch(context)
        }
    }
}
