import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite
struct ProviderEndpointOverrideSecurityLinuxTests {
    @Test
    func deepgramRejectsInsecureOverrideBeforeSendingToken() async {
        let transport = FailingTransport()
        do {
            _ = try await DeepgramUsageFetcher.fetchUsage(
                apiKey: "dg-test-token",
                environment: ["DEEPGRAM_API_URL": "http://attacker.test/v1"],
                transport: transport)
            Issue.record("Expected DeepgramUsageError.invalidEndpointOverride")
        } catch DeepgramUsageError.invalidEndpointOverride("DEEPGRAM_API_URL") {
            // Expected.
        } catch {
            Issue.record("Expected DeepgramUsageError.invalidEndpointOverride, got \(error)")
        }
    }

    @Test
    func zaiRejectsInsecureQuotaOverrideBeforeSendingToken() async {
        do {
            _ = try await ZaiUsageFetcher.fetchUsage(
                apiKey: "zai-test-token",
                environment: [ZaiSettingsReader.quotaURLKey: "http://attacker.test/quota"])
            Issue.record("Expected ZaiSettingsError.invalidEndpointOverride")
        } catch ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.quotaURLKey) {
            // Expected.
        } catch {
            Issue.record("Expected ZaiSettingsError.invalidEndpointOverride, got \(error)")
        }
    }

    @Test
    func zaiRejectsInsecureAPIHostOverride() {
        #expect(throws: ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.apiHostKey)) {
            try ZaiSettingsReader.validateEndpointOverrides(
                environment: [ZaiSettingsReader.apiHostKey: "http://attacker.test"])
        }
    }

    @Test
    func mimoRejectsInsecureOverrideBeforeSendingCookie() async {
        let transport = FailingTransport()
        do {
            _ = try await MiMoUsageFetcher.fetchUsage(
                cookieHeader: "api-platform_serviceToken=session-token; userId=user-1",
                environment: [MiMoSettingsReader.apiURLKey: "http://attacker.test/api/v1"],
                session: transport)
            Issue.record("Expected MiMoSettingsError.invalidEndpointOverride")
        } catch MiMoSettingsError.invalidEndpointOverride(MiMoSettingsReader.apiURLKey) {
            // Expected.
        } catch {
            Issue.record("Expected MiMoSettingsError.invalidEndpointOverride, got \(error)")
        }
    }

    @Test
    func affectedProviderOverridesAcceptHTTPSAndBareHosts() throws {
        try DeepgramUsageFetcher.validateEndpointOverrides(environment: ["DEEPGRAM_API_URL": "deepgram-proxy.test/v1"])
        try ZaiSettingsReader
            .validateEndpointOverrides(environment: [ZaiSettingsReader.quotaURLKey: "https://zai-proxy.test/quota"])
        try ZaiSettingsReader.validateEndpointOverrides(environment: [ZaiSettingsReader.apiHostKey: "localhost:9443"])
        try MiMoSettingsReader
            .validateEndpointOverrides(environment: [MiMoSettingsReader.apiURLKey: "mimo-proxy.test/api/v1"])

        #expect(ZaiSettingsReader.quotaURL(environment: [ZaiSettingsReader.quotaURLKey: "zai-proxy.test/quota"])?
            .absoluteString == "https://zai-proxy.test/quota")
        #expect(MiMoSettingsReader.apiURL(environment: [MiMoSettingsReader.apiURLKey: "mimo-proxy.test/api/v1"])
            .absoluteString == "https://mimo-proxy.test/api/v1")
    }
}

private struct FailingTransport: ProviderHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        Issue
            .record(
                "Endpoint override validation should fail before any request is sent to \(request.url?.absoluteString ?? "<nil>")")
        throw URLError(.badURL)
    }
}
