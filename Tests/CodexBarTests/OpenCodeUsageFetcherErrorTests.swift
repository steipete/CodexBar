import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct OpenCodeUsageFetcherErrorTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenCodeStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test
    func `extracts api error from uppercase HTML title`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = "<html><head><TITLE>403 Forbidden</TITLE></head><body>denied</body></html>"
            return Self.makeResponse(url: url, body: body, statusCode: 500, contentType: "text/html")
        }

        do {
            _ = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                workspaceIDOverride: "wrk_TEST123",
                session: self.makeSession())
            Issue.record("Expected OpenCodeUsageError.apiError")
        } catch let error as OpenCodeUsageError {
            switch error {
            case let .apiError(message):
                #expect(message.contains("HTTP 500"))
                #expect(message.contains("403 Forbidden"))
            default:
                Issue.record("Expected apiError, got: \(error)")
            }
        }
    }

    @Test
    func `extracts api error from detail field`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = #"{"detail":"Workspace missing"}"#
            return Self.makeResponse(url: url, body: body, statusCode: 500, contentType: "application/json")
        }

        do {
            _ = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                workspaceIDOverride: "wrk_TEST123",
                session: self.makeSession())
            Issue.record("Expected OpenCodeUsageError.apiError")
        } catch let error as OpenCodeUsageError {
            switch error {
            case let .apiError(message):
                #expect(message.contains("HTTP 500"))
                #expect(message.contains("Workspace missing"))
            default:
                Issue.record("Expected apiError, got: \(error)")
            }
        }
    }

    @Test
    func `subscription get null skips post and returns graceful error`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        var urls: [URL] = []
        var queries: [String] = []
        var contentTypes: [String] = []
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")
            urls.append(url)
            queries.append(url.query ?? "")
            contentTypes.append(request.value(forHTTPHeaderField: "Content-Type") ?? "")

            if request.httpMethod?.uppercased() == "GET" {
                return Self.makeResponse(url: url, body: "null", statusCode: 200, contentType: "application/json")
            }

            let body = #"{"status":500,"unhandled":true,"message":"HTTPError"}"#
            return Self.makeResponse(url: url, body: body, statusCode: 500, contentType: "application/json")
        }

        do {
            _ = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                workspaceIDOverride: "wrk_TEST123",
                session: self.makeSession())
            Issue.record("Expected OpenCodeUsageError.apiError")
        } catch let error as OpenCodeUsageError {
            switch error {
            case let .apiError(message):
                #expect(message.contains("No subscription usage data"))
                #expect(message.contains("wrk_TEST123"))
            default:
                Issue.record("Expected apiError, got: \(error)")
            }
        }

        // Subscription GET, then the billing lookup; the POST that answers HTTP 500 is never sent.
        #expect(methods == ["GET", "GET"])
        #expect(queries[0].contains("id="))
        #expect(queries[0].contains("wrk_TEST123"))
        #expect(urls[0].path == "/_server")
        #expect(contentTypes[0].isEmpty)
    }

    @Test
    func `pay as you go workspace reports monthly spend instead of failing`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")

            if request.value(forHTTPHeaderField: "X-Server-Id") == Self.billingServerID {
                return Self.makeResponse(
                    url: url,
                    body: Self.billingPayload,
                    statusCode: 200,
                    contentType: "text/javascript")
            }
            // The subscription server function resolves to null for workspaces without a subscription.
            return Self.makeResponse(
                url: url,
                body: Self.nullServerFunctionPayload,
                statusCode: 200,
                contentType: "text/javascript")
        }

        let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            workspaceIDOverride: "wrk_TEST123",
            session: self.makeSession())

        let payAsYouGo = try #require(snapshot.payAsYouGo)
        #expect(payAsYouGo.monthlyUsageUSD == 15)
        #expect(payAsYouGo.monthlyLimitUSD == 20)
        #expect(payAsYouGo.balanceUSD == 12.5)
        #expect(payAsYouGo.usedPercent == 75)
        #expect(methods == ["GET", "GET"])
    }

    @Test
    func `subscription post failure falls back to billing usage`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")

            if request.value(forHTTPHeaderField: "X-Server-Id") == Self.billingServerID {
                return Self.makeResponse(
                    url: url,
                    body: Self.billingPayload,
                    statusCode: 200,
                    contentType: "text/javascript")
            }
            if request.httpMethod?.uppercased() == "GET" {
                return Self.makeResponse(
                    url: url,
                    body: #"{"ok":true}"#,
                    statusCode: 200,
                    contentType: "application/json")
            }
            return Self.makeResponse(
                url: url,
                body: #"{"status":500,"unhandled":true,"message":"HTTPError"}"#,
                statusCode: 500,
                contentType: "application/json")
        }

        let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            workspaceIDOverride: "wrk_TEST123",
            session: self.makeSession())

        #expect(snapshot.payAsYouGo?.usedPercent == 75)
        #expect(methods == ["GET", "POST", "GET"])
    }

    @Test
    func `subscription failure is preserved when billing still has a subscription`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")

            if request.value(forHTTPHeaderField: "X-Server-Id") == Self.billingServerID {
                return Self.makeResponse(
                    url: url,
                    body: Self.subscriptionBillingPayload,
                    statusCode: 200,
                    contentType: "application/json")
            }
            if request.httpMethod?.uppercased() == "GET" {
                return Self.makeResponse(
                    url: url,
                    body: #"{"ok":true}"#,
                    statusCode: 200,
                    contentType: "application/json")
            }
            return Self.makeResponse(
                url: url,
                body: #"{"status":500,"unhandled":true,"message":"HTTPError"}"#,
                statusCode: 500,
                contentType: "application/json")
        }

        do {
            _ = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                workspaceIDOverride: "wrk_TEST123",
                session: self.makeSession())
            Issue.record("Expected the subscription API error to be preserved.")
        } catch let error as OpenCodeUsageError {
            switch error {
            case let .apiError(message):
                #expect(message.contains("HTTP 500"))
            default:
                Issue.record("Expected apiError, got: \(error)")
            }
        }

        #expect(methods == ["GET", "POST", "GET"])
    }

    @Test
    func `billing fallback surfaces expired session as invalid credentials`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if request.value(forHTTPHeaderField: "X-Server-Id") == Self.billingServerID {
                return Self.makeResponse(
                    url: url,
                    body: "<html><body>Please sign in to continue</body></html>",
                    statusCode: 200,
                    contentType: "text/html")
            }
            return Self.makeResponse(
                url: url,
                body: Self.nullServerFunctionPayload,
                statusCode: 200,
                contentType: "text/javascript")
        }

        do {
            _ = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                workspaceIDOverride: "wrk_TEST123",
                session: self.makeSession())
            Issue.record("Expected OpenCodeUsageError.invalidCredentials")
        } catch let error as OpenCodeUsageError {
            switch error {
            case .invalidCredentials:
                break
            default:
                Issue.record("Expected invalidCredentials, got: \(error)")
            }
        }
    }

    @Test
    func `subscription get payload does not fallback to post`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")

            let body = """
            {
              "rollingUsage": { "usagePercent": 17, "resetInSec": 600 },
              "weeklyUsage": { "usagePercent": 75, "resetInSec": 7200 }
            }
            """
            return Self.makeResponse(url: url, body: body, statusCode: 200, contentType: "application/json")
        }

        let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            workspaceIDOverride: "wrk_TEST123",
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 17)
        #expect(snapshot.weeklyUsagePercent == 75)
        #expect(methods == ["GET"])
    }

    @Test
    func `workspace get public actor error is treated as invalid credentials without post retry`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")
            let body = [
                #";0x00000263;((self.$R=self.$R||{})["server-fn:test"]=[],"#,
                #"($R=>$R[0]=Object.assign(new Error("actor of type \"public\" is not associated with an account"),"#,
                #"{stack:"Error: actor of type \"public\" is not associated with an account"}))"#,
                #"($R["server-fn:test"]))"#,
            ].joined()
            return Self.makeResponse(
                url: url,
                body: body,
                statusCode: 200,
                contentType: "text/javascript")
        }

        do {
            _ = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                session: self.makeSession())
            Issue.record("Expected OpenCodeUsageError.invalidCredentials")
        } catch let error as OpenCodeUsageError {
            switch error {
            case .invalidCredentials:
                break
            default:
                Issue.record("Expected invalidCredentials, got: \(error)")
            }
        }

        #expect(methods == ["GET"])
    }

    @Test
    func `subscription get missing fields falls back to post`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        var methods: [String] = []
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            methods.append(request.httpMethod ?? "GET")

            if request.httpMethod?.uppercased() == "GET" {
                return Self.makeResponse(
                    url: url,
                    body: #"{"ok":true}"#,
                    statusCode: 200,
                    contentType: "application/json")
            }

            let body = """
            {
              "rollingUsage": { "usagePercent": 22, "resetInSec": 300 },
              "weeklyUsage": { "usagePercent": 44, "resetInSec": 3600 }
            }
            """
            return Self.makeResponse(
                url: url,
                body: body,
                statusCode: 200,
                contentType: "application/json")
        }

        let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            workspaceIDOverride: "wrk_TEST123",
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 22)
        #expect(snapshot.weeklyUsagePercent == 44)
        #expect(methods == ["GET", "POST"])
    }

    @Test
    func `fetcher sends only auth cookie to opencode host`() async throws {
        defer {
            OpenCodeStubURLProtocol.handler = nil
        }

        var observedCookie: String?
        OpenCodeStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            observedCookie = request.value(forHTTPHeaderField: "Cookie")

            let body = """
            {
              "rollingUsage": { "usagePercent": 17, "resetInSec": 600 },
              "weeklyUsage": { "usagePercent": 75, "resetInSec": 7200 }
            }
            """
            return Self.makeResponse(url: url, body: body, statusCode: 200, contentType: "application/json")
        }

        _ = try await OpenCodeUsageFetcher.fetchUsage(
            cookieHeader: "provider=google; auth=test",
            timeout: 2,
            workspaceIDOverride: "wrk_TEST123",
            session: self.makeSession())

        #expect(observedCookie == "auth=test")
    }

    private static let billingServerID = "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"

    /// Shape opencode.ai returns when a server function resolves to null.
    private static let nullServerFunctionPayload =
        #";0x00000051;((self.$R=self.$R||{})["server-fn:test"]=[],null)"#

    /// Redacted customer/billing payload for a pay-as-you-go workspace: $15.00 spent of a $20
    /// monthly limit, $12.50 prepaid balance left. Amounts arrive scaled by 1e8.
    private static let billingPayload = [
        #";0x000002b9;((self.$R=self.$R||{})["server-fn:test"]=[],($R=>$R[0]={customerID:"cus_TEST","#,
        #"paymentMethodID:"pm_TEST",paymentMethodType:"link",paymentMethodLast4:null,balance:1250000000,"#,
        #"reload:!0,reloadAmount:10,reloadAmountMin:10,reloadTrigger:5,reloadTriggerMin:5,monthlyLimit:20,"#,
        #"monthlyUsage:1500000000,timeMonthlyUsageUpdated:$R[1]=new Date("2026-07-29T14:45:11.000Z"),"#,
        #"reloadError:null,timeReloadError:null,subscription:null,subscriptionID:null,subscriptionPlan:null,"#,
        #"lite:$R[2]={},liteSubscriptionID:"sub_TEST"})($R["server-fn:test"]))"#,
    ].joined()

    private static let subscriptionBillingPayload = """
    {
      "customerID": "cus_TEST",
      "monthlyUsage": 1500000000,
      "monthlyLimit": 20,
      "balance": 1250000000,
      "subscription": {"id": "sub_TEST"}
    }
    """

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int,
        contentType: String) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        return (response, Data(body.utf8))
    }
}

final class OpenCodeStubURLProtocol: URLProtocol {
    private static let _handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "opencode.ai"
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
