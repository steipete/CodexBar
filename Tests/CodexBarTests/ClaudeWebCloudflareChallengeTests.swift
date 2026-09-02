import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeWebCloudflareChallengeTests {
    private static let expectedChallengeMessage =
        "claude.ai is behind a Cloudflare challenge, often caused by VPN or datacenter networks. " +
        "Re-authenticating will not help. Switch Claude Usage source to OAuth in Settings " +
        "(Usage credits balance will be unavailable), or try a different network."

    @Test
    func `Cloudflare mitigation header has challenge recovery guidance`() async {
        let error = await Self.fetchError(
            statusCode: 403,
            headers: ["cf-mitigated": "challenge"],
            body: "challenge")

        #expect(error.localizedDescription == Self.expectedChallengeMessage)
    }

    @Test
    func `Cloudflare interstitial body has challenge recovery guidance`() async {
        let error = await Self.fetchError(
            statusCode: 403,
            headers: [:],
            body: "<html><title>Just a moment...</title></html>",
            challengedPath: "/api/organizations/org-123/usage")

        #expect(error.localizedDescription == Self.expectedChallengeMessage)
    }

    @Test
    func `ordinary forbidden response retains web sign in guidance`() async {
        let error = await Self.fetchError(statusCode: 403, headers: [:], body: "forbidden")

        #expect(error.localizedDescription == ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription)
    }

    @Test
    func `unauthorized response cannot become a Cloudflare challenge`() async {
        let error = await Self.fetchError(
            statusCode: 401,
            headers: ["cf-mitigated": "challenge"],
            body: "<title>Just a moment...</title>")

        #expect(error.localizedDescription == ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription)
    }

    private static func fetchError(
        statusCode: Int,
        headers: [String: String],
        body: String,
        challengedPath: String = "/api/organizations") async -> ClaudeWebAPIFetcher.FetchError
    {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            if url.path != challengedPath {
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                let data = Data(
                    #"[{"uuid":"org-123","name":"Test Org","capabilities":["chat"]}]"#.utf8)
                return (data, response)
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers))
            return (Data(body.utf8), response)
        }

        do {
            _ = try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
                try await ClaudeWebAPIFetcher.fetchUsage(cookieHeader: "sessionKey=sk-ant-test")
            }
            Issue.record("Expected Claude web fetch to fail")
            return .invalidResponse
        } catch let error as ClaudeWebAPIFetcher.FetchError {
            return error
        } catch {
            Issue.record("Unexpected error: \(error)")
            return .invalidResponse
        }
    }
}
