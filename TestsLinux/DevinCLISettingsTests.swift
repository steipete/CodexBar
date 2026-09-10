import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct DevinCLISettingsTests {
    private func settings(source: String? = "manual", token: String = "Bearer fixture-token") throws
        -> ProviderSettingsSnapshot
    {
        var provider = ["id": "devin", "cookieHeader": token, "workspaceID": "org_fixture"]
        provider["cookieSource"] = source
        let config = try JSONDecoder().decode(
            CodexBarConfig.self,
            from: JSONSerialization.data(withJSONObject: ["version": 1, "providers": [provider]]))
        let context = try TokenAccountCLIContext(
            selection: .init(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:])
        return try #require(context.settingsSnapshot(for: .devin, account: nil))
    }

    @Test(arguments: ["manual", nil])
    func `configured Devin bearer reaches the CLI request`(source: String?) async throws {
        let snapshot = try self.settings(source: source)
        let settings = try #require(snapshot.devin)
        #expect(settings.cookieSource == .manual)
        #expect(settings.manualBearerToken == "Bearer fixture-token")
        #expect(settings.organization == "org_fixture")
        #if os(Linux)
        for mode: ProviderSourceMode in [.auto, .web] {
            #expect(!CodexBarCLI.sourceModeRequiresWebSupport(mode, provider: .devin, settings: snapshot))
        }
        #endif

        let transport = DevinRequestFixture()
        let result = try await DevinUsageFetcher(browserDetection: BrowserDetection(homeDirectory: "/nonexistent"))
            .fetch(
                bearerTokenOverride: settings.bearerToken(environment: [:]),
                organizationOverride: settings.organization,
                transport: transport)
        #expect(result.daily?.usedPercent == 12)
        #expect(result.weekly?.usedPercent == 34)
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://app.devin.ai/api/org_fixture/billing/quota/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    }

    @Test(arguments: ["auto", "off"])
    func `environment token does not opt into manual auth`(source: String) throws {
        let snapshot = try self.settings(source: source)
        #expect(snapshot.devin?.cookieSource.rawValue == source)
        #if os(Linux)
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .devin,
            environment: ["DEVIN_BEARER_TOKEN": "environment-fixture"],
            settings: snapshot))
        #endif
    }

    @Test(arguments: ["environment-fixture", "", "  "])
    func `manual gate and request token preserve environment precedence`(token: String) throws {
        let snapshot = try self.settings()
        let settings = try #require(snapshot.devin)
        let environment = ["DEVIN_BEARER_TOKEN": token, "DEVIN_AUTHORIZATION": "fallback-fixture"]
        #expect(settings.bearerToken(environment: environment) == token)
        #expect(settings.bearerToken(environment: ["DEVIN_AUTHORIZATION": "fallback-fixture"]) == "fallback-fixture")
        #if os(Linux)
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .devin,
            environment: environment,
            settings: snapshot) == token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #endif
    }

    @Test
    func `blank configured manual token stays unavailable`() throws {
        let snapshot = try self.settings(token: "  ")
        #expect(DevinUsageFetcher.manualAuth(from: snapshot.devin?.bearerToken(environment: [:])) == nil)
        #if os(Linux)
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .devin, settings: snapshot))
        #endif
    }
}

private actor DevinRequestFixture: ProviderHTTPTransport {
    var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests.append(request)
        let url = try #require(request.url)
        return try (
            Data(#"{"daily_percentage":12,"weekly_percentage":34}"#.utf8),
            #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)))
    }
}
