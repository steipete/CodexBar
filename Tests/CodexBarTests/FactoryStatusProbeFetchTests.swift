import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct FactoryStatusProbeFetchTests {
    @Test
    func `clears stored Factory session when cached header is not logged in`() async throws {
        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
        }

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(url: url, body: "{}", statusCode: 401)
        }

        let cookie = try #require(HTTPCookie(properties: [
            .domain: "app.factory.ai",
            .path: "/",
            .name: "session",
            .value: "stale-session",
        ]))

        await FactorySessionStore.shared.clearSession()
        CookieHeaderCache.store(provider: .factory, cookieHeader: "session=stale-cache", sourceLabel: "Chrome")
        await FactorySessionStore.shared.setCookies([cookie])
        await FactorySessionStore.shared.setBearerToken("stale-bearer")
        await FactorySessionStore.shared.setRefreshToken("stale-refresh")
        defer {
            CookieHeaderCache.clear(provider: .factory)
        }

        let probe = FactoryStatusProbe(
            timeout: 0.1,
            browserDetection: BrowserDetection(
                homeDirectory: "/tmp/codexbar-empty-browser-home",
                cacheTTL: 0,
                fileExists: { _ in false },
                directoryContents: { _ in nil }))

        do {
            _ = try await probe.fetch()
        } catch FactoryStatusProbeError.notLoggedIn {
        } catch FactoryStatusProbeError.noSessionCookie {
        } catch {}

        #expect(CookieHeaderCache.load(provider: .factory) == nil)
        #expect(await FactorySessionStore.shared.getCookies().isEmpty)
        #expect(await FactorySessionStore.shared.getBearerToken() == nil)
        #expect(await FactorySessionStore.shared.getRefreshToken() == nil)
        await FactorySessionStore.shared.clearSession()
    }

    @Test
    func `fetches snapshot using cookie header override`() async throws {
        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
        }

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let path = url.path
            if path == "/api/app/auth/me" {
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
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if path == "/api/organization/subscription/usage" {
                let body = """
                {
                  "usage": {
                    "startDate": 1700000000000,
                    "endDate": 1700003600000,
                    "standard": {
                      "userTokens": 100,
                      "orgTotalTokensUsed": 250,
                      "totalAllowance": 1000,
                      "usedRatio": 0.10
                    },
                    "premium": {
                      "userTokens": 10,
                      "orgTotalTokensUsed": 20,
                      "totalAllowance": 100,
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
        let snapshot = try await probe.fetch(cookieHeaderOverride: "access-token=test.jwt.token; session=abc")

        #expect(snapshot.standardUserTokens == 100)
        #expect(snapshot.standardAllowance == 1000)
        #expect(snapshot.standardUsedRatio == 0.10)
        #expect(snapshot.premiumUserTokens == 10)
        #expect(snapshot.premiumUsedRatio == 0.10)
        #expect(snapshot.userId == "user-1")
        #expect(snapshot.planName == "Team")

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 10)
        #expect(usage.secondary?.usedPercent == 10)
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

final class FactoryStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.hasSuffix("factory.ai") || host == "api.workos.com"
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
