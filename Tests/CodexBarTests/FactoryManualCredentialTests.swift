import CodexBarCore
import Foundation
import Testing

extension FactoryStatusProbeFetchTests {
    @Test
    func `rejects malformed manual override before cached cookies`() async throws {
        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
            FactoryStubURLProtocol.requests = []
            CookieHeaderCache.clear(provider: .factory)
        }
        FactoryStubURLProtocol.requests = []
        CookieHeaderCache.store(provider: .factory, cookieHeader: "session=cached", sourceLabel: "Chrome")
        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(url: url, body: "{}", statusCode: 200)
        }

        let probe = FactoryStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        await #expect {
            _ = try await probe.fetch(cookieHeaderOverride: "definitely not a cookie or bearer")
        } throws: { error in
            guard case FactoryStatusProbeError.noSessionCookie = error else { return false }
            return true
        }
        #expect(FactoryStubURLProtocol.requests.isEmpty)
    }

    @Test
    func `falls back to bearer authorization when pasted cookie is stale`() async throws {
        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
            FactoryStubURLProtocol.requests = []
        }
        FactoryStubURLProtocol.requests = []

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if request.value(forHTTPHeaderField: "Cookie")?.contains("stale-session") == true {
                return Self.makeResponse(url: url, body: "{}", statusCode: 401)
            }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer factory-access-token" else {
                return Self.makeResponse(url: url, body: "{}", statusCode: 401)
            }
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            if url.host == "api.factory.ai", url.path == "/api/app/auth/me" {
                let body = """
                {
                  "organization": {
                    "id": "org_1",
                    "name": "Acme",
                    "subscription": {
                      "factoryTier": "team",
                      "orbSubscription": {
                        "plan": { "name": "Team", "id": "plan_1" },
                        "status": "active"
                      }
                    }
                  },
                  "userProfile": {
                    "id": "user-1",
                    "email": "user@example.com"
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.host == "api.factory.ai", url.path == "/api/billing/limits" {
                return Self.makeResponse(url: url, body: "{}", statusCode: 404)
            }
            if url.host == "api.factory.ai", url.path == "/api/organization/subscription/usage" {
                let body = """
                {
                  "usage": {
                    "standard": {
                      "userTokens": 100,
                      "totalAllowance": 1000,
                      "usedRatio": 0.10
                    }
                  },
                  "userId": "user-1"
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let probe = FactoryStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let snapshot = try await probe.fetch(
            cookieHeaderOverride: "Cookie: session=stale-session\nAuthorization: Bearer factory-access-token")

        #expect(snapshot.userId == "user-1")
        #expect(snapshot.standardUserTokens == 100)
        #expect(snapshot.standardAllowance == 1000)
        #expect(Self.requestTrace() == [
            "GET app.factory.ai/api/app/auth/me",
            "GET auth.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/billing/limits",
            "GET api.factory.ai/api/organization/subscription/usage?useCache=true&userId=user-1",
        ])
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

    private static func requestTrace() -> [String] {
        FactoryStubURLProtocol.requests.compactMap { request in
            guard let url = request.url else { return nil }
            let query = url.query.map { "?\($0)" } ?? ""
            return "\(request.httpMethod ?? "?") \(url.host ?? "unknown")\(url.path)\(query)"
        }
    }
}
