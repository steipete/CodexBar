import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct GroqActivityFetcherTests {
    private static let sampleBody = #"""
    {
        "object": "list",
        "data": [
            {
                "organization_id": "org_01htvnjbpbf6k8hca1xazyb3ck",
                "organization_name": "Personal",
                "n_context_tokens_total": 10228,
                "n_non_cached_context_tokens_total": 10228,
                "n_generated_tokens_total": 3659,
                "project_id": "project_01jtkg1anxfcxs05rgwm534zf5",
                "api_key_id": "key_01j0c939z4etdrrtbectztjqzq",
                "api_key_name": "travellm",
                "api_key_redacted": "gsk_***4CHP",
                "model": "llama3-8b-8192",
                "timestamp": 1718323200,
                "user_id": "",
                "user": "",
                "num_requests": 77,
                "num_seconds": 0,
                "service_tier": "on_demand",
                "cost": 0.00080412
            },
            {
                "organization_id": "org_01htvnjbpbf6k8hca1xazyb3ck",
                "organization_name": "Personal",
                "n_context_tokens_total": 449485,
                "n_non_cached_context_tokens_total": 449485,
                "n_generated_tokens_total": 424383,
                "project_id": "project_01jtkg1anxfcxs05rgwm534zf5",
                "api_key_id": "key_01j0c939z4etdrrtbectztjqzq",
                "api_key_name": "travellm",
                "api_key_redacted": "gsk_***4CHP",
                "model": "deepseek-r1-distill-llama-70b",
                "timestamp": 1738195200,
                "user_id": "",
                "user": "",
                "num_requests": 221,
                "num_seconds": 0,
                "num_seconds_billed": 0,
                "service_tier": "on_demand",
                "cost": 0
            }
        ]
    }
    """#

    @Test
    func `parses activity response and aggregates cost and tokens`() throws {
        let ref = Date(timeIntervalSince1970: 0)
        let snapshot = try GroqActivityFetcher._parseSnapshotForTesting(
            Data(Self.sampleBody.utf8),
            startDate: ref,
            endDate: ref,
            updatedAt: ref)

        #expect(snapshot.organizationName == "Personal")
        #expect(abs(snapshot.totalCost - 0.00080412) < 0.0000001)
        #expect(snapshot.totalContextTokens == 10228 + 449485)
        #expect(snapshot.totalGeneratedTokens == 3659 + 424383)
        #expect(snapshot.totalRequests == 77 + 221)
    }

    @Test
    func `toUsageSnapshot sets spend as login method`() throws {
        let ref = Date(timeIntervalSince1970: 0)
        let snapshot = try GroqActivityFetcher._parseSnapshotForTesting(
            Data(Self.sampleBody.utf8),
            startDate: ref,
            endDate: ref,
            updatedAt: ref)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.loginMethod(for: .groq)?.contains("$0.0008") == true)
        #expect(usage.accountOrganization(for: .groq) == "Personal")
    }

    @Test
    func `toUsageSnapshot shows zero spend when all costs are zero`() throws {
        let body = #"{"object":"list","data":[]}"#
        let ref = Date(timeIntervalSince1970: 0)
        let snapshot = try GroqActivityFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            startDate: ref,
            endDate: ref,
            updatedAt: ref)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.totalCost == 0)
        #expect(usage.loginMethod(for: .groq)?.contains("$0.0000") == true)
    }

    @Test
    func `fetch activity sends correct headers and query params`() async throws {
        let registered = URLProtocol.registerClass(GroqStubURLProtocol.self)
        defer {
            if registered { URLProtocol.unregisterClass(GroqStubURLProtocol.self) }
            GroqStubURLProtocol.handler = nil
        }

        GroqStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path.contains("org_testid"))
            #expect(url.query?.contains("start_date=") == true)
            #expect(url.query?.contains("end_date=") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.value(forHTTPHeaderField: "groq-organization") == "org_testid")
            return Self.makeResponse(url: url, body: Self.sampleBody, statusCode: 200)
        }

        let env = [
            GroqSettingsReader.sessionTokenEnvironmentKey: "test-token",
            GroqSettingsReader.orgIDEnvironmentKey: "org_testid",
            GroqSettingsReader.apiURLEnvironmentKey: "https://groq.test",
        ]
        let snapshot = try await GroqActivityFetcher.fetchActivity(
            token: "test-token",
            orgID: "org_testid",
            environment: env)

        #expect(snapshot.totalRequests == 77 + 221)
    }

    @Test
    func `settings reader extracts org ID from JWT payload`() {
        // Header.Payload.Signature — payload is base64url of {"https://groq.com/organization":{"id":"org_abc123"}}
        let payload = #"{"https://groq.com/organization":{"id":"org_abc123"},"sub":"member-live-xyz"}"#
        let b64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJSUzI1NiJ9.\(b64).fakesig"

        let orgID = GroqSettingsReader.extractOrgID(fromJWT: jwt)
        #expect(orgID == "org_abc123")
    }

    @Test
    func `settings reader returns nil for non-JWT token`() {
        #expect(GroqSettingsReader.extractOrgID(fromJWT: "not-a-jwt") == nil)
        #expect(GroqSettingsReader.extractOrgID(fromJWT: "") == nil)
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }
}

final class GroqStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "groq.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
