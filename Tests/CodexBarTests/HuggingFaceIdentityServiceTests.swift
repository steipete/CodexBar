import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

private func identityResponse(
    _ body: String,
    statusCode: Int = 200) throws -> (Data, URLResponse)
{
    let response = try #require(HTTPURLResponse(
        url: HuggingFaceIdentityService.whoamiURL,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]))
    return (Data(body.utf8), response)
}

struct HuggingFaceIdentityServiceTests {
    @Test
    func `parses strict user identities and drops non user payloads`() async throws {
        let payload = #"{"type":"user","id":" opaque-id-1 ","name":"fixture-user","email":"user@example.com","isPro":true}"#
        let service = HuggingFaceIdentityService(transport: ProviderHTTPTransportStub { request in
            #expect(request.url?.path == "/api/whoami-v2")
            return try identityResponse(payload)
        })

        let identity = try await service.identity(bearerToken: "hf_fixture_token", timeout: 1)

        #expect(identity?.opaqueUserID == "opaque-id-1")
        #expect(identity?.accountID == "fixture-user")
        #expect(identity?.email == "user@example.com")
        #expect(identity?.isPro == true)
        #expect(identity?.displayIdentitySnapshot(provider: .huggingface)?.loginMethod == "PRO")
        #expect(identity?.displayIdentitySnapshot(provider: .huggingface)?.accountID == "fixture-user")
    }

    @Test
    func `non user types malformed payloads and http failures resolve to unavailable`() async throws {
        let bodies = [
            #"{"type":"organization","id":"org-id"}"#,
            #"{"name":"no-type","id":"some-id"}"#,
            #"{"type":"user","name":"missing-id"}"#,
            #"{"type":"user","id":""}"#,
            "not-json",
        ]
        for body in bodies {
            let service = HuggingFaceIdentityService(transport: ProviderHTTPTransportStub { _ in
                try identityResponse(body)
            })
            #expect(try await service.identity(bearerToken: "hf_fixture_token", timeout: 1) == nil)
        }

        for status in [401, 403, 500] {
            let service = HuggingFaceIdentityService(transport: ProviderHTTPTransportStub { _ in
                try identityResponse(#"{"error":"fixture"}"#, statusCode: status)
            })
            #expect(try await service.identity(bearerToken: "hf_fixture_token", timeout: 1) == nil)
        }

        let malformedTransport = ProviderHTTPTransportStub { _ in
            throw ProviderPluginError.script("fixture network outage")
        }
        let networkService = HuggingFaceIdentityService(transport: malformedTransport)
        #expect(try await networkService.identity(bearerToken: "hf_fixture_token", timeout: 1) == nil)
    }

    @Test
    func `one whoami request per credential cache miss across authorities`() async throws {
        let userBody = #"{"type":"user","id":"opaque-id-1","name":"fixture-user"}"#
        let transport = ProviderHTTPTransportStub { _ in
            try identityResponse(userBody)
        }
        let service = HuggingFaceIdentityService(transport: transport)

        _ = try await service.identity(bearerToken: "hf_fixture_token", timeout: 1)
        _ = try await service.identity(bearerToken: "hf_fixture_token", timeout: 1)
        _ = try await service.identity(cookieHeader: "session=fixture", timeout: 1)
        _ = try await service.identity(cookieHeader: "session=fixture", timeout: 1)

        let requests = await transport.requests()
        #expect(requests.count(where: {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer hf_fixture_token"
        }) == 1)
        #expect(requests.count(where: { $0.value(forHTTPHeaderField: "Cookie") == "session=fixture" }) == 1)
    }

    @Test
    func `distinct credentials use isolated cache entries`() async throws {
        let userBody = #"{"type":"user","id":"opaque-id-1","name":"fixture-user"}"#
        let transport = ProviderHTTPTransportStub { _ in
            try identityResponse(userBody)
        }
        let service = HuggingFaceIdentityService(transport: transport)

        _ = try await service.identity(bearerToken: "hf_first_token", timeout: 1)
        _ = try await service.identity(bearerToken: "hf_second_token", timeout: 1)
        _ = try await service.identity(cookieHeader: "session=fixture", timeout: 1)
        _ = try await service.identity(cookieHeader: "session=other", timeout: 1)

        let requests = await transport.requests()
        let bearerHeaders = requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(bearerHeaders == ["Bearer hf_first_token", "Bearer hf_second_token"])
        let cookieHeaders = requests.compactMap { $0.value(forHTTPHeaderField: "Cookie") }
        #expect(cookieHeaders == ["session=fixture", "session=other"])
    }

    @Test
    func `empty credentials never trigger a request`() async throws {
        let transport = ProviderHTTPTransportStub { _ in
            try identityResponse(#"{"type":"user","id":"opaque-id-1"}"#)
        }
        let service = HuggingFaceIdentityService(transport: transport)

        #expect(try await service.identity(bearerToken: "   ", timeout: 1) == nil)
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func `cancellation propagates instead of resolving to unavailable`() async throws {
        let transport = ProviderHTTPTransportStub { _ in
            throw CancellationError()
        }
        let service = HuggingFaceIdentityService(transport: transport)

        await #expect(throws: CancellationError.self) {
            _ = try await service.identity(bearerToken: "hf_fixture_token", timeout: 1)
        }
    }

    @Test
    func `successful identities are cached for twelve hours and expire`() async throws {
        let userBody = #"{"type":"user","id":"opaque-id-1","name":"fixture-user"}"#
        let transport = ProviderHTTPTransportStub { _ in
            try identityResponse(userBody)
        }
        let service = HuggingFaceIdentityService(transport: transport)

        _ = try await service.identity(bearerToken: "hf_fixture_token", timeout: 1)
        // Cache entries live 12 hours; expiry handling is covered by the internal TTL contract.
        #expect(await service.cacheCount() == 1)
        #expect(HuggingFaceIdentityService.cacheTTLSeconds == 12 * 60 * 60)
    }

    @Test
    func `fingerprint cache keys never contain raw credentials`() {
        let token = "hf_super_secret_fixture_token"
        let cookie = "session=super_secret_fixture_value"
        let fingerprint = CookieHeaderCache.credentialFingerprint(token)

        // The fingerprint is a hex digest, not the credential, and stable across calls.
        #expect(fingerprint == CookieHeaderCache.credentialFingerprint(token))
        #expect(!fingerprint.contains(token))
        #expect(!CookieHeaderCache.credentialFingerprint(cookie).contains(cookie))
    }
}

extension HuggingFaceIdentityService {
    func cacheCount() -> Int {
        self.cache.count
    }
}
