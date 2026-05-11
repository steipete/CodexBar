import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct MoonshotUsageFetcherTests {
    @Test
    func `parses documented response`() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "available_balance": 49.58,
            "voucher_balance": 50.00,
            "cash_balance": 12.34
          },
          "scode": "0x0",
          "status": true
        }
        """

        let summary = try MoonshotUsageFetcher._parseSummaryForTesting(Data(json.utf8))

        #expect(summary.availableBalance == 49.58)
        #expect(summary.voucherBalance == 50.00)
        #expect(summary.cashBalance == 12.34)

        let usage = MoonshotUsageSnapshot(summary: summary).toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.loginMethod(for: .moonshot) == "Balance: $49.58")
    }

    @Test
    func `negative cash balance is surfaced as deficit`() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "available_balance": 49.58,
            "voucher_balance": 50.00,
            "cash_balance": -0.42
          },
          "scode": "0x0",
          "status": true
        }
        """

        let summary = try MoonshotUsageFetcher._parseSummaryForTesting(Data(json.utf8))
        let usage = MoonshotUsageSnapshot(summary: summary).toUsageSnapshot()

        #expect(summary.cashBalance == -0.42)
        #expect(usage.loginMethod(for: .moonshot)?.contains("in deficit") == true)
    }

    @Test
    func `invalid root returns parse error`() {
        let json = """
        [{ "available_balance": 1 }]
        """

        #expect {
            _ = try MoonshotUsageFetcher._parseSummaryForTesting(Data(json.utf8))
        } throws: { error in
            guard case MoonshotUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `api code failure returns api error`() {
        let json = """
        {
          "code": 401,
          "data": {
            "available_balance": 0,
            "voucher_balance": 0,
            "cash_balance": 0
          },
          "scode": "unauthorized",
          "status": false
        }
        """

        #expect {
            _ = try MoonshotUsageFetcher._parseSummaryForTesting(Data(json.utf8))
        } throws: { error in
            guard case let MoonshotUsageError.apiError(message) = error else { return false }
            return message == "code 401, scode unauthorized"
        }
    }

    @Test
    func `international host uses moonshot ai`() {
        let url = MoonshotUsageFetcher.resolveBalanceURL(region: .international)

        #expect(url.absoluteString == "https://api.moonshot.ai/v1/users/me/balance")
    }

    @Test
    func `china host uses moonshot cn`() {
        let url = MoonshotUsageFetcher.resolveBalanceURL(region: .china)

        #expect(url.absoluteString == "https://api.moonshot.cn/v1/users/me/balance")
    }

    @Test
    func `fetch usage sends bearer token and bounded request`() async throws {
        defer {
            MoonshotStubURLProtocol.requests = []
            MoonshotStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MoonshotStubURLProtocol.self]
        let session = URLSession(configuration: config)

        MoonshotStubURLProtocol.requests = []
        MoonshotStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://api.moonshot.cn/v1/users/me/balance")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live-token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)

            let body = """
            {
              "code": 0,
              "data": {
                "available_balance": 9.87,
                "voucher_balance": 1.23,
                "cash_balance": 8.64
              },
              "scode": "0x0",
              "status": true
            }
            """
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(body.utf8))
        }

        let snapshot = try await MoonshotUsageFetcher.fetchUsage(
            apiKey: " live-token ",
            region: .china,
            session: session)

        #expect(MoonshotStubURLProtocol.requests.count == 1)
        #expect(snapshot.summary.availableBalance == 9.87)
        #expect(snapshot.toUsageSnapshot().loginMethod(for: .moonshot) == "Balance: $9.87")
    }

    @Test
    func `fetch usage surfaces http failure without leaking body`() async throws {
        defer {
            MoonshotStubURLProtocol.requests = []
            MoonshotStubURLProtocol.handler = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MoonshotStubURLProtocol.self]
        let session = URLSession(configuration: config)

        MoonshotStubURLProtocol.requests = []
        MoonshotStubURLProtocol.handler = { request in
            let url = try #require(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(#"{"error":"secret-ish provider body"}"#.utf8))
        }

        await #expect {
            _ = try await MoonshotUsageFetcher.fetchUsage(
                apiKey: "live-token",
                session: session)
        } throws: { error in
            guard case let MoonshotUsageError.apiError(message) = error else { return false }
            return message == "HTTP 401"
        }
    }
}

final class MoonshotStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool {
        true
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
