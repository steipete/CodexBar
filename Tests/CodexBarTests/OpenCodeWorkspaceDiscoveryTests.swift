import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct OpenCodeWorkspaceDiscoveryTests {
    @Test
    func discoveriesReturnTypedLabelsAndOwnersThroughInjectedSession() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }
        OpenCodeStubURLProtocol.handler = { request in
            let body = """
            {
              "data": [
                {"id": "wrk_ALPHA", "name": "Alpha Workspace", "owner": {"name": "Alice"}},
                {"id": "wrk_BETA", "label": "Beta Workspace", "owner": {"email": "bob@example.test"}}
              ]
            }
            """
            return try Self.makeResponse(url: #require(request.url), body: body, statusCode: 200)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let workspaces = try await OpenCodeWorkspaceDiscovery.discover(
            cookieHeader: "auth=test",
            timeout: 2,
            session: session)

        #expect(workspaces.map(\.workspaceID) == ["wrk_ALPHA", "wrk_BETA"])
        #expect(workspaces.map(\.label) == ["Alpha Workspace", "Beta Workspace"])
        #expect(workspaces.map(\.ownerLabel) == ["Alice", "bob@example.test"])
    }

    @Test
    func discoveryResultExposesMissingCredentialsAndFailures() async {
        defer { OpenCodeStubURLProtocol.handler = nil }
        OpenCodeStubURLProtocol.handler = { request in
            try Self.makeResponse(url: #require(request.url), body: "{}", statusCode: 500)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let missing = await OpenCodeWorkspaceDiscovery.resolve(
            cookieHeader: nil,
            timeout: 2,
            session: session)
        #expect(missing == .missingReusableCredential)

        let failure = await OpenCodeWorkspaceDiscovery.resolve(
            cookieHeader: "auth=test",
            timeout: 2,
            session: session)
        guard case .discoveryFailed = failure else {
            Issue.record("Expected a discovery failure result")
            return
        }
    }

    @Test
    @MainActor
    func failedImportDoesNotPersistFirstTimeCredential() async throws {
        defer { OpenCodeStubURLProtocol.handler = nil }
        OpenCodeStubURLProtocol.handler = { request in
            try Self.makeResponse(url: #require(request.url), body: "{}", statusCode: 500)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suite = "OpenCodeWorkspaceDiscoveryTests-import-no-persist"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.opencodeCookieSource = .manual
        settings.opencodeCookieHeader = "auth=import"

        let results = try await settings.importOpenCodeWorkspaceAccounts(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 2,
            session: session)

        #expect(results.count == 1)
        guard case let .discoveryFailed(message) = results[0] else {
            Issue.record("Expected a typed discovery failure result")
            return
        }
        #expect(message.contains("HTTP 500"))
        #expect(settings.tokenAccounts(for: .opencode).isEmpty)
        #expect(settings.opencodeWorkspaceAccounts.accounts.isEmpty)
    }

    @Test
    @MainActor
    func importMapsDiscoveryFailureToTypedMutationResult() async throws {
        defer { OpenCodeStubURLProtocol.handler = nil }
        OpenCodeStubURLProtocol.handler = { request in
            try Self.makeResponse(url: #require(request.url), body: "{}", statusCode: 500)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suite = "OpenCodeWorkspaceDiscoveryTests-import-failure"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.addTokenAccount(provider: .opencode, label: "Shared", token: "auth=shared")

        let results = try await settings.importOpenCodeWorkspaceAccounts(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 2,
            session: session)

        #expect(results.count == 1)
        guard case .discoveryFailed = results[0] else {
            Issue.record("Expected a typed discovery failure result")
            return
        }
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }
}
