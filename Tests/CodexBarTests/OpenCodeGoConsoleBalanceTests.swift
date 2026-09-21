import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct OpenCodeGoConsoleBalanceTests {
    @Test(arguments: ["null", #"{"access":null}"#], [false, true])
    func `migrated pay as you go session reports balance without subscription windows`(
        goStatus: String,
        includeZenBalance: Bool) async throws
    {
        defer { ConsoleBalanceURLProtocol.handler = nil }
        ConsoleBalanceURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "__Host-console_session=synthetic")
            switch url.path {
            case "/console/api/orgs":
                #expect(request.value(forHTTPHeaderField: "x-org-id") == nil)
                return Self.response(url, body: #"[{"id":"wrk_SYNTHETIC"}]"#)
            case "/console/api/go/status":
                #expect(request.value(forHTTPHeaderField: "x-org-id") == "wrk_SYNTHETIC")
                return Self.response(url, body: goStatus)
            case "/console/api/billing/status":
                #expect(request.value(forHTTPHeaderField: "x-org-id") == "wrk_SYNTHETIC")
                return Self.response(url, body: Self.billingStatus)
            default:
                Issue.record("Console-only session attempted legacy route \(url.path)")
                return Self.response(url, body: "{}", statusCode: 401)
            }
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "__Host-console_session=synthetic",
            timeout: 2,
            includeZenBalance: includeZenBalance,
            session: Self.session())

        #expect(snapshot.isBalanceOnly)
        #expect(try #require(snapshot.zenBalanceUSD) == 12.3456789)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.providerCost?.used == 12.3456789)
    }

    @Test(arguments: [403, 404, 500])
    func `failed legacy page cannot turn console API failure into balance only success`(code: Int) async throws {
        defer { ConsoleBalanceURLProtocol.handler = nil }
        ConsoleBalanceURLProtocol.handler = { request in
            let url = try #require(request.url)
            switch url.path {
            case "/console/api/go/status":
                return Self.response(url, body: "{}", statusCode: code)
            case "/workspace/wrk_SYNTHETIC/go":
                return Self.response(url, body: "<html><title>Console</title><div id='app'></div></html>")
            default:
                Issue.record("Console API failure incorrectly triggered a billing read")
                return Self.response(url, body: Self.billingStatus)
            }
        }
        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "auth=legacy; __Host-console_session=console",
                timeout: 2,
                workspaceIDOverride: "wrk_SYNTHETIC",
                includeZenBalance: false,
                session: Self.session())
            Issue.record("Expected Console API failure")
        } catch let error as OpenCodeGoUsageError {
            guard case let .apiError(message) = error else {
                Issue.record("Expected Console API failure, got \(error)")
                return
            }
            #expect(message.contains(String(code)))
        }
    }

    @Test
    func `stale legacy cookie cannot invalidate a console balance only session`() async throws {
        defer { ConsoleBalanceURLProtocol.handler = nil }
        ConsoleBalanceURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/console/api/go/status" { return Self.response(url, body: "null") }
            if url.path == "/console/api/billing/status" { return Self.response(url, body: Self.billingStatus) }
            return Self.response(url, body: "{}", statusCode: 401)
        }
        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=expired; __Host-console_session=console",
            timeout: 2,
            workspaceIDOverride: "wrk_SYNTHETIC",
            includeZenBalance: false,
            session: Self.session())
        #expect(snapshot.isBalanceOnly)
        #expect(snapshot.zenBalanceUSD == 12.3456789)
    }

    @Test(arguments: ["{}", #"{"access":{}}"#, "invalid"])
    func `malformed console usage cannot erase quota as balance only success`(payload: String) async throws {
        defer { ConsoleBalanceURLProtocol.handler = nil }
        ConsoleBalanceURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/console/api/go/status" { return Self.response(url, body: payload) }
            Issue.record("Malformed usage incorrectly triggered a balance read")
            return Self.response(url, body: Self.billingStatus)
        }
        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "__Host-console_session=console",
                timeout: 2,
                workspaceIDOverride: "wrk_SYNTHETIC",
                includeZenBalance: false,
                session: Self.session())
            Issue.record("Expected malformed usage failure")
        } catch let error as OpenCodeGoUsageError {
            guard case let .parseFailed(message) = error else {
                Issue.record("Expected parse failure, got \(error)")
                return
            }
            #expect(message == "Invalid Console usage payload.")
        }
    }

    @Test(arguments: ["seat", "credit", "legacy"])
    func `recognized unsupported billing never falls back to a legacy balance`(mode: String) async throws {
        defer { ConsoleBalanceURLProtocol.handler = nil }
        ConsoleBalanceURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(url.path == "/console/api/billing/status")
            return Self.response(url, body: Self.billingStatus.replacingOccurrences(of: "prepaid", with: mode))
        }
        let balance = try await OpenCodeGoUsageFetcher.fetchOptionalZenBalance(
            cookieHeader: "auth=legacy; __Host-console_session=console",
            timeout: 2,
            workspaceIDOverride: "wrk_SYNTHETIC",
            session: Self.session())
        #expect(balance == nil)
    }

    @Test(arguments: ["0", "-125000000", "1234567890"])
    func `console balances retain zero negative and fractional dollars`(raw: String) throws {
        let text = Self.billingStatus.replacingOccurrences(of: "1234567890", with: raw)
        #expect(try OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(text: text) == Double(raw)! / 100_000_000)
    }

    @Test(arguments: ["null", "true", "12", #""NaN""#, #""Infinity""#, #""1e999""#, #""1.5""#])
    func `malformed console balances never use available credit`(raw: String) {
        let text = Self.billingStatus.replacingOccurrences(of: #""1234567890""#, with: raw)
        #expect(throws: OpenCodeGoUsageError.self) {
            try OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(text: text)
        }
    }

    @Test(arguments: ["seat", "credit", "legacy"])
    func `unsupported console billing modes do not become prepaid balances`(mode: String) throws {
        let text = Self.billingStatus.replacingOccurrences(of: "prepaid", with: mode)
        #expect(try OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(text: text) == nil)
    }

    @Test
    func `console balance requires its explicit prepaid pay as you go contract`() throws {
        #expect(throws: OpenCodeGoUsageError.self) {
            try OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(
                text: Self.billingStatus.replacingOccurrences(of: #""billingMode":"prepaid","#, with: ""))
        }
        #expect(try OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(
            text: Self.billingStatus.replacingOccurrences(of: "pay-as-you-go", with: "invoiceable")) == nil)
        #expect(throws: OpenCodeGoUsageError.self) {
            try OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(
                text: Self.billingStatus.replacingOccurrences(of: #""balanceMicroCents":"1234567890","#, with: ""))
        }
    }

    @Test
    func `console billing forbidden preserves the authenticated session`() async throws {
        defer { ConsoleBalanceURLProtocol.handler = nil }
        ConsoleBalanceURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/console/api/go/status" {
                return Self.response(url, body: "null")
            }
            return Self.response(url, body: #"{"_tag":"Forbidden"}"#, statusCode: 403)
        }

        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "__Host-console_session=synthetic",
                timeout: 2,
                workspaceIDOverride: "wrk_SYNTHETIC",
                includeZenBalance: false,
                session: Self.session())
            Issue.record("Expected billing permission failure")
        } catch let error as OpenCodeGoUsageError {
            guard case let .apiError(message) = error else {
                Issue.record("Expected API permission failure, got \(error)")
                return
            }
            #expect(message.contains("403"))
        }
    }

    @Test(arguments: [403, 404])
    func `empty legacy balance does not hide a console billing access failure`(code: Int) async throws {
        defer { ConsoleBalanceURLProtocol.handler = nil }
        ConsoleBalanceURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/console/api/go/status" { return Self.response(url, body: "null") }
            if url.path == "/console/api/billing/status" {
                return Self.response(url, body: "{}", statusCode: code)
            }
            return Self.response(url, body: "{}")
        }
        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "auth=legacy; __Host-console_session=console",
                timeout: 2,
                workspaceIDOverride: "wrk_SYNTHETIC",
                includeZenBalance: false,
                session: Self.session())
            Issue.record("Expected Console billing access failure")
        } catch let error as OpenCodeGoUsageError {
            guard case let .apiError(message) = error else {
                Issue.record("Expected Console API failure, got \(error)")
                return
            }
            #expect(message.contains(String(code)))
        }
    }

    @Test(arguments: [200, 403, -1001])
    func `optional console billing failures preserve subscription quota`(code: Int) async throws {
        defer { ConsoleBalanceURLProtocol.handler = nil }
        ConsoleBalanceURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/console/api/go/status" {
                return Self.response(url, body: """
                {"access":{"meters":{"fiveHour":{"usedMicroCents":"25","limitMicroCents":"100"}}}}
                """)
            }
            #expect(url.path == "/console/api/billing/status")
            if code < 0 { throw URLError(.timedOut) }
            return Self.response(url, body: "{}", statusCode: code)
        }
        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "__Host-console_session=synthetic",
            timeout: 2,
            workspaceIDOverride: "wrk_SYNTHETIC",
            waitForZenBalance: true,
            session: Self.session())
        #expect(!snapshot.isBalanceOnly)
        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.zenBalanceUSD == nil)
    }

    private static let billingStatus = """
    {"billingMode":"prepaid","mode":"pay-as-you-go","balanceMicroCents":"1234567890",\
    "availableMicroCents":"9876543210","creditLimitMicroCents":null}
    """

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsoleBalanceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        (HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
    }
}

private final class ConsoleBalanceURLProtocol: URLProtocol {
    private static let handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self.handlerBox.value }
        set { Self.handlerBox.setValue(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "opencode.ai"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
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
