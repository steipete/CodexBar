import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct MiniMaxAPITokenFetchTests {
    @Test
    func retriesChinaHostWhenGlobalRejectsToken() async throws {
        let registered = URLProtocol.registerClass(MiniMaxAPITokenStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(MiniMaxAPITokenStubURLProtocol.self)
            }
            MiniMaxAPITokenStubURLProtocol.handler = nil
            MiniMaxAPITokenStubURLProtocol.requests = []
        }

        MiniMaxAPITokenStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let host = url.host ?? ""
            if host == "api.minimax.io" {
                return Self.makeResponse(url: url, body: "{}", statusCode: 401)
            }
            if host == "api.minimaxi.com" {
                let start = 1_700_000_000_000
                let end = start + 5 * 60 * 60 * 1000
                let body = """
                {
                  "base_resp": { "status_code": 0 },
                  "current_subscribe_title": "Max",
                  "model_remains": [
                    {
                      "current_interval_total_count": 1000,
                      "current_interval_usage_count": 250,
                      "start_time": \(start),
                      "end_time": \(end),
                      "remains_time": 240000
                    }
                  ]
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(apiToken: "sk-cp-test", region: .global, now: now)

        #expect(snapshot.planName == "Max")
        #expect(MiniMaxAPITokenStubURLProtocol.requests.count == 2)
        #expect(MiniMaxAPITokenStubURLProtocol.requests.first?.url?.host == "api.minimax.io")
        #expect(MiniMaxAPITokenStubURLProtocol.requests.last?.url?.host == "api.minimaxi.com")
    }

    @Test
    func preservesInvalidCredentialsWhenChinaRetryFailsTransport() async throws {
        let registered = URLProtocol.registerClass(MiniMaxAPITokenStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(MiniMaxAPITokenStubURLProtocol.self)
            }
            MiniMaxAPITokenStubURLProtocol.handler = nil
            MiniMaxAPITokenStubURLProtocol.requests = []
        }

        MiniMaxAPITokenStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let host = url.host ?? ""
            if host == "api.minimax.io" {
                return Self.makeResponse(url: url, body: "{}", statusCode: 401)
            }
            if host == "api.minimaxi.com" {
                throw URLError(.cannotFindHost)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            _ = try await MiniMaxUsageFetcher.fetchUsage(apiToken: "sk-cp-test", region: .global, now: now)
        }

        #expect(MiniMaxAPITokenStubURLProtocol.requests.count == 2)
        #expect(MiniMaxAPITokenStubURLProtocol.requests.first?.url?.host == "api.minimax.io")
        #expect(MiniMaxAPITokenStubURLProtocol.requests.last?.url?.host == "api.minimaxi.com")
    }

    @Test
    func doesNotRetryWhenRegionIsChinaMainland() async throws {
        let registered = URLProtocol.registerClass(MiniMaxAPITokenStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(MiniMaxAPITokenStubURLProtocol.self)
            }
            MiniMaxAPITokenStubURLProtocol.handler = nil
            MiniMaxAPITokenStubURLProtocol.requests = []
        }

        MiniMaxAPITokenStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let host = url.host ?? ""
            if host == "api.minimaxi.com" {
                let start = 1_700_000_000_000
                let end = start + 5 * 60 * 60 * 1000
                let body = """
                {
                  "base_resp": { "status_code": 0 },
                  "current_subscribe_title": "Max",
                  "model_remains": [
                    {
                      "current_interval_total_count": 1000,
                      "current_interval_usage_count": 250,
                      "start_time": \(start),
                      "end_time": \(end),
                      "remains_time": 240000
                    }
                  ]
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 401)
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await MiniMaxUsageFetcher.fetchUsage(apiToken: "sk-cp-test", region: .chinaMainland, now: now)

        #expect(MiniMaxAPITokenStubURLProtocol.requests.count == 1)
        #expect(MiniMaxAPITokenStubURLProtocol.requests.first?.url?.host == "api.minimaxi.com")
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

final class MiniMaxAPITokenStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "api.minimax.io" || host == "api.minimaxi.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(self.request)
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
