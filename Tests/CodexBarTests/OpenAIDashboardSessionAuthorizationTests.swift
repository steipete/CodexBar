#if os(macOS)
import Foundation
import Testing
@testable import CodexBarCore

@MainActor
struct OpenAIDashboardSessionAuthorizationTests {
    @Test(arguments: [0.0, 1234.0])
    func `cookie retry pairs workspace balance with the same session identity`(balance: Double) async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "chatgpt.com")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let stage = Self.stage(request)
            #expect(request.value(forHTTPHeaderField: "Authorization") ==
                (["retry", "balance"].contains(stage) ? "Bearer fixture-token" : nil))
            if stage == "balance" {
                #expect(request.url?.path == "/backend-api/accounts/workspace-fixture/remaining_balance")
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-fixture")
            }
            return try Self.response(request, balance: balance)
        }
        var messages: [String] = []
        let result = try await self.fetch(transport, logger: { messages.append($0) })
        let response = try #require(result)

        #expect(response.verifiedSignedInEmail == "owner@example.com")
        #expect(response.apiData.creditsRemaining == balance)
        #expect(response.apiData.balanceIsWorkspace == true)
        #expect(response.apiData.primaryLimit?.usedPercent == 12)
        #expect(await transport.requests().map(Self.stage) == ["initial", "session", "retry", "balance"])
        #expect(!messages.joined().contains("fixture-token"))
        #expect(!messages.joined().contains("owner@example.com"))
        let dashboard = try OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: response.apiData,
            verifiedEmail: #require(response.verifiedSignedInEmail),
            previous: nil)
        let encoded = try JSONEncoder().encode(dashboard)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("fixture-token"))
        #expect(dashboard.toCreditsSnapshot()?.displayRemaining == balance)
    }

    @Test
    func `successful cookie usage does not fetch a session or invent an authenticated email`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return try Self.httpResponse(request, status: 200, payload: Self.usage(balance: "14"))
        }
        let result = try await self.fetch(transport)

        #expect(result?.apiData.creditsRemaining == 14)
        #expect(result?.verifiedSignedInEmail == nil)
        #expect(await transport.requests().map(Self.stage) == ["initial"])
    }

    @Test(arguments: [
        "not-json",
        #"{}"#,
        #"{"accessToken":"fixture-token","email":"other@example.com"}"#,
        #"{"accessToken":"fixture-token","user":{"email":""}}"#,
        #"{"accessToken":"fixture-token","user":{"email":" \n "}}"#,
        #"{"accessToken":"fixture-token","user":{"email":123}}"#,
        #"{"user":{"email":"owner@example.com"}}"#,
        #"{"accessToken":null,"user":{"email":"owner@example.com"}}"#,
        #"{"accessToken":"","user":{"email":"owner@example.com"}}"#,
        #"{"accessToken":" ","user":{"email":"owner@example.com"}}"#,
        #"{"accessToken":"fixture token","user":{"email":"owner@example.com"}}"#,
        #"{"accessToken":"fixture-token\n","user":{"email":"owner@example.com"}}"#,
        #"{"accessToken":"fixture\u0000token","user":{"email":"owner@example.com"}}"#,
    ])
    func `invalid typed session credentials cannot authorize a retry`(payload: String) async throws {
        let transport = ProviderHTTPTransportStub { request in
            if Self.stage(request) == "session" {
                return try Self.httpResponse(request, status: 200, payload: payload)
            }
            return try Self.response(request)
        }
        #expect(try await self.fetch(transport) == nil)
        #expect(await transport.requests().map(Self.stage) == ["initial", "session"])
    }

    @Test(arguments: [403, 429, 500])
    func `nonauthentication usage failures do not start session authentication`(status: Int) async throws {
        let transport = ProviderHTTPTransportStub { request in
            try Self.httpResponse(request, status: status, payload: "{}")
        }
        #expect(try await self.fetch(transport) == nil)
        #expect(await transport.requests().map(Self.stage) == ["initial"])
    }

    @Test
    func `malformed successful usage does not start session authentication`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            try Self.httpResponse(request, status: 200, payload: "not-json")
        }
        #expect(try await self.fetch(transport) == nil)
        #expect(await transport.requests().map(Self.stage) == ["initial"])
    }

    @Test(arguments: [401, 403, 500])
    func `session HTTP failures stop before bearer usage`(status: Int) async throws {
        let transport = ProviderHTTPTransportStub { request in
            if Self.stage(request) == "session" {
                return try Self.httpResponse(request, status: status, payload: "{}")
            }
            return try Self.response(request)
        }
        #expect(try await self.fetch(transport) == nil)
        #expect(await transport.requests().map(Self.stage) == ["initial", "session"])
    }

    @Test
    func `a second usage authentication failure does not repeat session bootstrap`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            if Self.stage(request) == "retry" {
                return try Self.httpResponse(request, status: 401, payload: "{}")
            }
            return try Self.response(request)
        }
        #expect(try await self.fetch(transport) == nil)
        #expect(await transport.requests().map(Self.stage) == ["initial", "session", "retry"])
    }

    @Test
    func `independent cookies keep their bearer identity and workspace isolated`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let isFirst = request.value(forHTTPHeaderField: "Cookie") == "session=first"
            let name = isFirst ? "first" : "second"
            let stage = Self.stage(request)
            if stage == "session" {
                return try Self.httpResponse(request, status: 200, payload: Self.session(
                    token: "fixture-\(name)", email: "\(name)@example.com"))
            }
            if stage == "retry" || stage == "balance" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-\(name)")
            }
            if stage == "retry" {
                return try Self.httpResponse(request, status: 200, payload: Self.usage(account: "workspace-\(name)"))
            }
            if stage == "balance" {
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-\(name)")
                #expect(request.url?.path == "/backend-api/accounts/workspace-\(name)/remaining_balance")
            }
            return try Self.response(request, balance: isFirst ? 1234 : 1200)
        }
        let first = try await self.fetch(transport, cookie: "session=first")
        let second = try await self.fetch(transport, cookie: "session=second")

        #expect(first?.verifiedSignedInEmail == "first@example.com")
        #expect(second?.verifiedSignedInEmail == "second@example.com")
        #expect(first?.apiData.creditsRemaining == 1234)
        #expect(second?.apiData.creditsRemaining == 1200)
        #expect(await transport.requests().count == 8)
    }

    @Test(arguments: [false, true], [401, 403])
    func `optional unauthorized enrichments retain authenticated usage without reauthenticating`(
        hideBalance: Bool,
        status: Int) async throws
    {
        let transport = ProviderHTTPTransportStub { request in
            let stage = Self.stage(request)
            if stage == "monthly" || stage == "balance" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
                #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
            }
            if stage == "monthly" || (hideBalance && stage == "balance") {
                return try Self.httpResponse(request, status: status, payload: "{}")
            }
            return try Self.response(request, includeMonthly: true)
        }
        let result = try await self.fetch(transport)

        #expect(result?.verifiedSignedInEmail == "owner@example.com")
        #expect(result?.apiData.primaryLimit?.usedPercent == 12)
        #expect(result?.apiData.codexCreditLimit == nil)
        #expect(result?.apiData.creditsAvailable == true)
        #expect(result?.apiData.creditsRemaining == (hideBalance ? nil : 1234))
        #expect(result?.apiData.balanceIsWorkspace == (hideBalance ? nil : true))
        #expect(await transport.requests().map(Self.stage) == ["initial", "session", "retry", "monthly", "balance"])
    }

    @Test
    func `an expired shared deadline sends no authentication requests`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            Issue.record("Expired dashboard requests must not reach the transport")
            return try Self.response(request)
        }
        #expect(try await self.fetch(transport, deadline: .distantPast) == nil)
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func `deadline expiry after cookie rejection prevents the session request`() async throws {
        let deadline = Date().addingTimeInterval(1)
        let transport = ProviderHTTPTransportStub { request in
            #expect(Self.stage(request) == "initial")
            // The transport deliberately returns after the shared budget; retries must recheck it.
            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 0.01))
            return try Self.httpResponse(request, status: 401, payload: "{}")
        }
        #expect(try await self.fetch(transport, deadline: deadline) == nil)
        #expect(await transport.requests().map(Self.stage) == ["initial"])
    }

    @Test
    func `session retry and optional requests share the remaining deadline`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.timeoutInterval > 0)
            #expect(request.timeoutInterval <= 3.5)
            if Self.stage(request) == "session" {
                #expect(request.timeoutInterval <= 2)
            }
            return try Self.response(request, includeMonthly: true)
        }
        let result = try await self.fetch(transport, deadline: Date().addingTimeInterval(3.5))

        #expect(result?.apiData.creditsRemaining == 1234)
        let requests = await transport.requests()
        #expect(requests.count == 5)
        let usageAndEnrichment = requests.filter { Self.stage($0) != "session" }
        #expect(zip(usageAndEnrichment, usageAndEnrichment.dropFirst()).allSatisfy {
            $0.0.timeoutInterval >= $0.1.timeoutInterval
        })
    }

    @Test
    func `cancellation before fetch sends no requests`() async {
        let transport = ProviderHTTPTransportStub { request in
            Issue.record("Cancelled dashboard requests must not reach the transport")
            return try Self.response(request)
        }
        let task = Task { @MainActor in
            _ = try await self.fetch(transport)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test(arguments: ["initial", "session", "retry", "monthly", "balance"])
    func `cancellation after a transport response stops the authentication sequence`(stage: String) async {
        let transport = ProviderHTTPTransportStub { request in
            if Self.stage(request) == stage {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return try Self.response(request, includeMonthly: true)
        }
        let task = Task { @MainActor in
            _ = try await self.fetch(transport)
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        let stages = await transport.requests().map(Self.stage)
        #expect(stages.last == stage)
        #expect(stages == Array(["initial", "session", "retry", "monthly", "balance"].prefix(stages.count)))
    }

    @Test(arguments: ["initial", "session", "retry", "monthly", "balance"])
    func `transport cancellation remains terminal during optional enrichment`(stage: String) async {
        let transport = ProviderHTTPTransportStub { request in
            if Self.stage(request) == stage {
                throw URLError(.cancelled)
            }
            return try Self.response(request, includeMonthly: true)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await self.fetch(transport)
        }
        #expect(await transport.requests().map(Self.stage).last == stage)
    }

    private func fetch(
        _ transport: ProviderHTTPTransportStub,
        cookie: String = "session=fixture",
        deadline: Date? = nil,
        logger: @escaping (String) -> Void = { _ in }) async throws -> OpenAIDashboardFetcher.DashboardAPIResponse?
    {
        try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            try await OpenAIDashboardFetcher.fetchDashboardAPIResponse(
                cookieHeader: cookie,
                deadline: deadline,
                logger: logger)
        }
    }

    private nonisolated static func stage(_ request: URLRequest) -> String {
        switch request.url?.path {
        case "/api/auth/session": "session"
        case let path? where path.hasSuffix("/monthly-usage"): "monthly"
        case let path? where path.hasSuffix("/remaining_balance"): "balance"
        default: request.value(forHTTPHeaderField: "Authorization") == nil ? "initial" : "retry"
        }
    }

    private nonisolated static func session(
        token: String = "fixture-token", email: String = "owner@example.com") -> String
    {
        // Only the explicit session user identifies the bearer, even when other objects contain emails.
        #"{"accessToken":"\#(token)","user":{"email":" \#(email) "},"other":{"email":"other@example.com"}}"#
    }

    private nonisolated static func usage(
        account: String = "workspace-fixture", balance: String = "null", includeMonthly: Bool = false) -> String
    {
        let monthly = includeMonthly ? #", "spend_control":{"individual_limit":null}"# : ""
        return """
        {"account_id":"\(account)","plan_type":"business",
         "rate_limit":{"primary_window":{"used_percent":12,"reset_at":1700003600,"limit_window_seconds":18000}},
         "credits":{"has_credits":true,"unlimited":false,"balance":\(balance)}\(monthly)}
        """
    }

    private nonisolated static func response(
        _ request: URLRequest, balance: Double = 1234, includeMonthly: Bool = false) throws -> (Data, URLResponse)
    {
        let stage = self.stage(request)
        let payload = switch stage {
        case "session": self.session()
        case "retry": self.usage(includeMonthly: includeMonthly)
        case "balance": #"{"balance":"\#(balance)"}"#
        default: "{}"
        }
        return try self.httpResponse(
            request,
            status: stage == "initial" || stage == "monthly" ? 401 : 200,
            payload: payload)
    }

    private nonisolated static func httpResponse(
        _ request: URLRequest, status: Int, payload: String) throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(payload.utf8), response)
    }
}
#endif
