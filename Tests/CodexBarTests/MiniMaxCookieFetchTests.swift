import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct MiniMaxCookieFetchTests {
    @Test
    func `enriches html snapshot with remains data when html parse succeeds`() async throws {
        let registered = URLProtocol.registerClass(MiniMaxCookieFetchStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(MiniMaxCookieFetchStubURLProtocol.self)
            }
            MiniMaxCookieFetchStubURLProtocol.handler = nil
            MiniMaxCookieFetchStubURLProtocol.requests = []
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + 5 * 60 * 60 * 1000

        MiniMaxCookieFetchStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            switch url.path {
            case let path where path.contains("user-center/payment/coding-plan"):
                // Simulate a slow HTML response so the remains task completes first
                DispatchQueue.global().sync { Thread.sleep(forTimeInterval: 0.25) }
                let html = """
                <div>Coding Plan</div>
                <div>Max</div>
                <div>Available usage: 1,500 prompts / 5 hours</div>
                <div>Current Usage</div>
                <div>0% Used</div>
                <div>Resets in 4 min</div>
                """
                return Self.makeHTMLResponse(url: url, body: html)

            case let path where path.contains("v1/api/openplatform/coding_plan/remains"):
                let json = """
                {
                  "base_resp": { "status_code": 0 },
                  "model_remains": [
                    {
                      "current_interval_total_count": 4000,
                      "current_interval_usage_count": 4000,
                      "model_name": "speech-hd",
                      "current_weekly_total_count": 28000,
                      "current_weekly_usage_count": 28000,
                      "start_time": \(start),
                      "end_time": \(end),
                      "remains_time": 240000
                    },
                    {
                      "current_interval_total_count": 0,
                      "current_interval_usage_count": 0,
                      "model_name": "MiniMax-Hailuo-2.3-Fast-6s-768p",
                      "current_weekly_total_count": 0,
                      "current_weekly_usage_count": 0,
                      "start_time": \(start),
                      "end_time": \(end),
                      "remains_time": 240000
                    },
                    {
                      "current_interval_total_count": 1500,
                      "current_interval_usage_count": 1450,
                      "model_name": "MiniMax-M*",
                      "current_weekly_total_count": 0,
                      "current_weekly_usage_count": 0,
                      "start_time": \(start),
                      "end_time": \(end),
                      "remains_time": 240000
                    },
                    {
                      "current_interval_total_count": 50,
                      "current_interval_usage_count": 50,
                      "model_name": "image-01",
                      "current_weekly_total_count": 350,
                      "current_weekly_usage_count": 350,
                      "start_time": \(start),
                      "end_time": \(end),
                      "remains_time": 240000
                    }
                  ]
                }
                """
                return Self.makeJSONResponse(url: url, body: json)

            default:
                return Self.makeJSONResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "session=test-cookie",
            region: .global,
            environment: [:],
            now: now)

        #expect(MiniMaxCookieFetchStubURLProtocol.requests.count == 2)
        #expect(
            MiniMaxCookieFetchStubURLProtocol.requests.contains {
                $0.url?.path.contains("user-center/payment/coding-plan") == true
            })
        #expect(
            MiniMaxCookieFetchStubURLProtocol.requests.contains {
                $0.url?.path.contains("v1/api/openplatform/coding_plan/remains") == true
            })
        #expect(snapshot.planName == "Max")
        #expect(snapshot.availablePrompts == 1500)
        #expect(snapshot.currentPrompts == nil)
        #expect(snapshot.remainingPrompts == nil)
        #expect(snapshot.windowMinutes == 300)
        #expect(snapshot.usedPercent == 0)
        #expect(snapshot.resetsAt == now.addingTimeInterval(240))
        #expect(snapshot.modelEntries.map(\.modelName) == ["MiniMax-M*", "speech-hd", "image-01"])
    }

    @Test
    func `returns html snapshot without waiting for slow remains enrichment`() async throws {
        let registered = URLProtocol.registerClass(MiniMaxCookieFetchStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(MiniMaxCookieFetchStubURLProtocol.self)
            }
            MiniMaxCookieFetchStubURLProtocol.handler = nil
            MiniMaxCookieFetchStubURLProtocol.requests = []
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        MiniMaxCookieFetchStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            switch url.path {
            case let path where path.contains("user-center/payment/coding-plan"):
                let html = """
                <div>Coding Plan</div>
                <div>Max</div>
                <div>Available usage: 1,500 prompts / 5 hours</div>
                <div>Current Usage</div>
                <div>0% Used</div>
                <div>Resets in 4 min</div>
                """
                return Self.makeHTMLResponse(url: url, body: html)

            case let path where path.contains("v1/api/openplatform/coding_plan/remains"):
                // Simulate a slow remains response that exceeds the enrichment timeout (200ms)
                DispatchQueue.global().sync { Thread.sleep(forTimeInterval: 1.0) }
                let json = """
                {
                  "base_resp": { "status_code": 0 },
                  "current_subscribe_title": "Max",
                  "model_remains": [
                    {
                      "current_interval_total_count": 1500,
                      "current_interval_usage_count": 1450,
                      "model_name": "MiniMax-M*",
                      "current_weekly_total_count": 0,
                      "current_weekly_usage_count": 0,
                      "start_time": 1700000000000,
                      "end_time": 1700018000000,
                      "remains_time": 240000
                    }
                  ]
                }
                """
                return Self.makeJSONResponse(url: url, body: json)

            default:
                return Self.makeJSONResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "session=test-cookie",
            region: .global,
            environment: [:],
            now: now)

        // HTML returned successfully, but remains was too slow — no model entries merged
        #expect(snapshot.planName == "Max")
        #expect(snapshot.availablePrompts == 1500)
        #expect(snapshot.usedPercent == 0)
        #expect(snapshot.resetsAt == now.addingTimeInterval(240))
        #expect(snapshot.modelEntries.isEmpty)

        // Allow the slow remains background task to drain so URLProtocol cleanup is safe
        try? await Task.sleep(nanoseconds: 1_100_000_000)
    }

    @Test
    func `awaits remains fallback without timeout when html parse fails`() async throws {
        let registered = URLProtocol.registerClass(MiniMaxCookieFetchStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(MiniMaxCookieFetchStubURLProtocol.self)
            }
            MiniMaxCookieFetchStubURLProtocol.handler = nil
            MiniMaxCookieFetchStubURLProtocol.requests = []
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + 5 * 60 * 60 * 1000

        MiniMaxCookieFetchStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            switch url.path {
            case let path where path.contains("user-center/payment/coding-plan"):
                let html = """
                <div>unexpected html that no longer matches parser</div>
                """
                return Self.makeHTMLResponse(url: url, body: html)

            case let path where path.contains("v1/api/openplatform/coding_plan/remains"):
                // Simulate a slow remains response that exceeds the enrichment timeout.
                DispatchQueue.global().sync { Thread.sleep(forTimeInterval: 1.0) }
                let json = """
                {
                  "base_resp": { "status_code": 0 },
                  "current_subscribe_title": "Max",
                  "model_remains": [
                    {
                      "current_interval_total_count": 1500,
                      "current_interval_usage_count": 1450,
                      "model_name": "MiniMax-M*",
                      "current_weekly_total_count": 0,
                      "current_weekly_usage_count": 0,
                      "start_time": \(start),
                      "end_time": \(end),
                      "remains_time": 240000
                    }
                  ]
                }
                """
                return Self.makeJSONResponse(url: url, body: json)

            default:
                return Self.makeJSONResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "session=test-cookie",
            region: .global,
            environment: [:],
            now: now)

        #expect(snapshot.planName == "Max")
        #expect(snapshot.availablePrompts == 1500)
        #expect(snapshot.currentPrompts == 50)
        #expect(snapshot.remainingPrompts == 1450)
        #expect(snapshot.windowMinutes == 300)
        #expect(snapshot.usedPercent == (Double(50) / Double(1500) * 100))
        #expect(snapshot.modelEntries.map(\.modelName) == ["MiniMax-M*"])
    }

    private static func makeHTMLResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        return (response, Data(body.utf8))
    }

    private static func makeJSONResponse(
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

final class MiniMaxCookieFetchStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        return host == "platform.minimax.io" || host == "platform.minimaxi.com"
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
