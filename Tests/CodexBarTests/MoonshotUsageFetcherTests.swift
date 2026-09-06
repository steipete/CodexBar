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
        #expect(usage.loginMethod(for: .moonshot) == "Balance: $49.58 · $0.42 in deficit")
    }

    @Test
    func `china region balance renders CNY not USD`() throws {
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

        let summary = try MoonshotUsageFetcher._parseSummaryForTesting(Data(json.utf8), region: .china)
        let usage = MoonshotUsageSnapshot(summary: summary).toUsageSnapshot()

        #expect(summary.region == .china)
        #expect(usage.loginMethod(for: .moonshot) == "Balance: CN¥49.58")
    }

    @Test
    func `china region deficit renders CNY not USD`() throws {
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

        let summary = try MoonshotUsageFetcher._parseSummaryForTesting(Data(json.utf8), region: .china)
        let usage = MoonshotUsageSnapshot(summary: summary).toUsageSnapshot()

        #expect(usage.loginMethod(for: .moonshot) == "Balance: CN¥49.58 · CN¥0.42 in deficit")
    }

    @Test(arguments: MoonshotRegion.allCases)
    func `zero balances retain their regional currency`(region: MoonshotRegion) {
        let summary = MoonshotUsageSummary(
            availableBalance: 0, voucherBalance: 0, cashBalance: 0, updatedAt: Date(), region: region)
        let expected = region == .china ? "Balance: CN¥0.00" : "Balance: $0.00"
        #expect(summary.toUsageSnapshot().loginMethod(for: .moonshot) == expected)
    }

    @Test(arguments: MoonshotRegion.allCases)
    func `presentation preserves formatted balance and deficit currency`(region: MoonshotRegion) {
        let usage = MoonshotUsageSummary(
            availableBalance: 9.87, voucherBalance: 9.87, cashBalance: -0.42, updatedAt: Date(), region: region)
            .toUsageSnapshot()
        let identity = MoonshotProviderDescriptor.descriptor.presentation.identity(provider: .moonshot, snapshot: usage)
        let expected = region == .china
            ? "Balance: CN¥9.87 · CN¥0.42 in deficit"
            : "Balance: $9.87 · $0.42 in deficit"
        #expect(identity.badge == expected)
        #expect(identity.plan == expected)
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

    @Test(arguments: MoonshotRegion.allCases)
    func `fetch usage sends bearer token and retains request region`(region: MoonshotRegion) async throws {
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
            let expectedURL = region == .china
                ? "https://api.moonshot.cn/v1/users/me/balance"
                : "https://api.moonshot.ai/v1/users/me/balance"
            #expect(url.absoluteString == expectedURL)
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
            region: region,
            session: session)

        #expect(MoonshotStubURLProtocol.requests.count == 1)
        #expect(snapshot.summary.region == region)
        #expect(snapshot.summary.availableBalance == 9.87)
        #expect(snapshot.summary.voucherBalance == 1.23)
        #expect(snapshot.summary.cashBalance == 8.64)
        let expected = region == .china ? "Balance: CN¥9.87" : "Balance: $9.87"
        #expect(snapshot.toUsageSnapshot().loginMethod(for: .moonshot) == expected)
    }

    @Test
    func `fetch usage defaults to international region and renders USD`() async throws {
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
            #expect(url.absoluteString == "https://api.moonshot.ai/v1/users/me/balance")

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

        let snapshot = try await MoonshotUsageFetcher.fetchUsage(apiKey: "live-token", session: session)

        #expect(snapshot.summary.region == .international)
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
    private static let _handlerBox = LockIsolated<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

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
