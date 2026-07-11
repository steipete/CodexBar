import Foundation
import Testing
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
        let missing = await OpenCodeWorkspaceDiscovery.resolve(
            cookieHeader: nil,
            timeout: 2,
            session: .shared)
        #expect(missing == .missingReusableCredential)

        let failure = await OpenCodeWorkspaceDiscovery.resolve(
            cookieHeader: "auth=test",
            timeout: 2,
            session: .shared)
        guard case .discoveryFailed = failure else {
            Issue.record("Expected a discovery failure result")
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
