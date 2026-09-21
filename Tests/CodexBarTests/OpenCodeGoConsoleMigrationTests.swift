import Foundation
import Testing
@testable import CodexBarCore

private final class ConsoleRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage.append(value)
    }

    var values: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }
}

/// Covers the migrated OpenCode Console contract at `opencode.ai/console`.
///
/// Migrated workspaces redirect the legacy `/workspace/<id>/go` page to the console login route and
/// answer with an empty SPA shell, so the scraped `rollingUsage` payload is gone. These regressions
/// pin the console JSON contract and keep the legacy page working for workspaces that have not
/// migrated yet.
@Suite(.serialized)
struct OpenCodeGoConsoleMigrationTests {
    private static let workspaceID = "wrk_TEST123"
    private static let now = Date(timeIntervalSince1970: 1_789_862_400) // 2026-09-20T00:00:00Z

    /// Micro-cent meters, matching the shape the console returns for a Go subscription.
    private static func goStatusJSON(
        fiveHourResetsAt: String = "\"2026-09-20T03:00:00.000Z\"",
        includeMonth: Bool = true) -> String
    {
        // The month meter carries no reset timestamp; the billing period end stands in for it.
        let month = includeMonth
            ? #","month":{"limitMicroCents":"6000000000","usedMicroCents":"600000000"}"#
            : ""
        return """
        {"renewalCurrency":"usd","useBalance":false,"cancelAtPeriodEnd":false,\
        "access":{"startsAt":"2026-09-19T00:00:00.000Z","endsAt":"2026-10-19T00:00:00.000Z","meters":{\
        "fiveHour":{"startsAt":"2026-09-19T23:00:00.000Z","resetsAt":\(fiveHourResetsAt),\
        "limitMicroCents":"1200000000","usedMicroCents":"300000000"},\
        "week":{"startsAt":"2026-09-14T00:00:00.000Z","resetsAt":"2026-09-21T00:00:00.000Z",\
        "limitMicroCents":"3000000000","usedMicroCents":"1200000000"}\(month)}}}
        """
    }

    /// The server-rendered payload a workspace that has not migrated still returns.
    private static let legacyUsagePageHTML = """
    <script>$R[41]={rollingUsage:$R[42]={status:"ok",resetInSec:5944,usagePercent:17},\
    weeklyUsage:$R[43]={status:"ok",resetInSec:278201,usagePercent:75},\
    monthlyUsage:$R[44]={status:"ok",resetInSec:880201,usagePercent:91}};</script>
    """

    /// The empty shell every console route serves, including the login redirect target.
    private static let consoleShellHTML = """
    <!DOCTYPE html><html><head><title>OpenCode Console</title>\
    <script type="module" src="/console/assets/index.js"></script></head><body><div id="app"></div></body></html>
    """

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConsoleMigrationURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200,
        contentType: String = "application/json") -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        return (response, Data(body.utf8))
    }

    @Test
    func `parses console micro-cent meters into usage windows`() throws {
        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(
            text: Self.goStatusJSON(),
            now: Self.now)

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 40)
        #expect(snapshot.hasWeeklyUsage == true)
        #expect(snapshot.hasMonthlyUsage == true)
        #expect(snapshot.monthlyUsagePercent == 10)
        #expect(snapshot.rollingResetInSec == 10800)
        #expect(snapshot.weeklyResetInSec == 86400)
        // 2026-09-20 -> 2026-10-19 is 29 days.
        #expect(snapshot.monthlyResetInSec == 2_505_600)
        #expect(snapshot.renewsAt == Date(timeIntervalSince1970: 1_792_368_000)) // 2026-10-19T00:00:00Z
    }

    @Test
    func `console five-hour window without a reset timestamp reports no countdown`() throws {
        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(
            text: Self.goStatusJSON(fiveHourResetsAt: "null"),
            now: Self.now)

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.rollingResetInSec == nil)
        #expect(snapshot.weeklyResetInSec == 86400)
        #expect(snapshot.toUsageSnapshot().primary?.resetsAt == nil)
        let encoded = try JSONEncoder().encode(snapshot.toUsageSnapshot())
        #expect(try JSONDecoder().decode(UsageSnapshot.self, from: encoded).primary?.resetsAt == nil)
        let legacy = try OpenCodeGoUsageFetcher.parseSubscription(text: Self.legacyUsage, now: Self.now)
        #expect(legacy.applyingWebUsage(snapshot).toUsageSnapshot().primary?.resetsAt == nil)
    }

    @Test
    func `null monthly reset uses the console billing period end`() throws {
        let text = Self.goStatusJSON().replacingOccurrences(
            of: #""month":{"#,
            with: #""month":{"resetsAt":null,"#)
        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(text: text, now: Self.now)
        #expect(snapshot.monthlyResetInSec == 2_505_600)
        #expect(snapshot.toUsageSnapshot().tertiary?.resetsAt == snapshot.renewsAt)
    }

    @Test
    func `console status without a month meter keeps weekly reporting`() throws {
        let snapshot = try OpenCodeGoUsageFetcher.parseSubscription(
            text: Self.goStatusJSON(includeMonth: false),
            now: Self.now)

        #expect(snapshot.hasMonthlyUsage == false)
        #expect(snapshot.monthlyUsagePercent == 0)
        #expect(snapshot.weeklyUsagePercent == 40)
    }

    @Test
    func `parses console workspace list`() {
        let text = #"[{"id":"wrk_TEST123","name":"Default"},{"id":"wrk_TEST456","name":"Team"}]"#
        #expect(OpenCodeGoUsageFetcher.parseConsoleWorkspaceIDs(text: text) == ["wrk_TEST123", "wrk_TEST456"])
        #expect(OpenCodeGoUsageFetcher.parseConsoleWorkspaceIDs(text: #"{"error":"nope"}"#).isEmpty)
        #expect(OpenCodeGoUsageFetcher.parseConsoleWorkspaceIDs(text: #"[{"id":"acc_TEST"}]"#).isEmpty)
    }

    @Test
    func `migrated workspace reads usage from the console API`() async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }

        let requests = ConsoleRequestRecorder()
        let workspaceHeaders = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            requests.append("\(request.httpMethod ?? "GET") \(url.path)")

            switch url.path {
            case "/console/api/orgs":
                return Self.makeResponse(url: url, body: #"[{"id":"wrk_TEST123","name":"Default"}]"#)
            case "/console/api/go/status":
                guard let workspaceID = request.value(forHTTPHeaderField: "x-org-id") else {
                    return Self.makeResponse(url: url, body: #"{"_tag":"BadRequest"}"#, statusCode: 400)
                }
                workspaceHeaders.append(workspaceID)
                return Self.makeResponse(url: url, body: Self.goStatusJSON())
            default:
                // Migrated workspaces serve the empty console shell on every legacy route.
                return Self.makeResponse(url: url, body: Self.consoleShellHTML, contentType: "text/html")
            }
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            now: Self.now,
            includeZenBalance: false,
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 40)
        #expect(snapshot.monthlyUsagePercent == 10)
        #expect(workspaceHeaders.values == [Self.workspaceID])
        #expect(requests.values == ["GET /console/api/orgs", "GET /console/api/go/status"])
    }

    @Test
    func `console workspace lookup is skipped when a workspace override is configured`() async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }

        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            requests.append("\(request.httpMethod ?? "GET") \(url.path)")
            guard url.path == "/console/api/go/status" else {
                return Self.makeResponse(url: url, body: Self.consoleShellHTML, contentType: "text/html")
            }
            return Self.makeResponse(url: url, body: Self.goStatusJSON())
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            now: Self.now,
            workspaceIDOverride: Self.workspaceID,
            includeZenBalance: false,
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(requests.values == ["GET /console/api/go/status"])
    }

    @Test(arguments: [false, true])
    func `console organization IDs preserve workspace scope`(workspaceOverride: Bool) async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }
        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            let url = try #require(request.url)
            requests.append(url.path)
            if url.path == "/console/api/orgs" {
                return Self.makeResponse(url: url, body: #"[{"id":"org_TEST123"}]"#)
            }
            #expect(url.path == "/console/api/go/status")
            #expect(request.value(forHTTPHeaderField: "x-org-id") == "org_TEST123")
            return Self.makeResponse(url: url, body: Self.goStatusJSON())
        }
        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "__Host-console_session=synthetic",
            timeout: 2,
            workspaceIDOverride: workspaceOverride ? "https://opencode.ai/console/org_TEST123/go" : nil,
            includeZenBalance: false,
            session: self.makeSession())
        #expect(snapshot.rollingUsagePercent == 25)
        let discovery = workspaceOverride ? [] : ["/console/api/orgs"]
        #expect(requests.values == discovery + ["/console/api/go/status"])
        #expect(OpenCodeGoUsageFetcher.dashboardURL(workspaceID: "org_TEST123").path == "/console/org_TEST123/go")
    }

    @Test
    func `unmigrated workspace falls back to the legacy usage page`() async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }

        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            requests.append("\(request.httpMethod ?? "GET") \(url.path)")

            if url.path == "/console/api/go/status" {
                // Workspaces that have not migrated are unknown to the console API.
                return Self.makeResponse(url: url, body: #"{"_tag":"NotFound"}"#, statusCode: 404)
            }
            let page = """
            <script>$R[41]={rollingUsage:$R[42]={status:"ok",resetInSec:5944,usagePercent:17},\
            weeklyUsage:$R[43]={status:"ok",resetInSec:278201,usagePercent:75},\
            monthlyUsage:$R[44]={status:"ok",resetInSec:880201,usagePercent:91}};</script>
            """
            return Self.makeResponse(url: url, body: page, contentType: "text/html")
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            now: Self.now,
            workspaceIDOverride: Self.workspaceID,
            includeZenBalance: false,
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 17)
        #expect(snapshot.weeklyUsagePercent == 75)
        #expect(snapshot.monthlyUsagePercent == 91)
        #expect(requests.values == ["GET /console/api/go/status", "GET /workspace/wrk_TEST123/go"])
    }

    /// The console uses a different cookie, so its rejection must not condemn a legacy session.
    @Test
    func `console rejection keeps a working legacy session`() async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }

        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            requests.append(url.path)

            if url.path.hasPrefix("/console/api/") {
                return Self.makeResponse(url: url, body: #"{"message":"Unauthorized"}"#, statusCode: 401)
            }
            if url.path == "/_server" {
                return Self.makeResponse(url: url, body: #"{"data":[{"id":"wrk_TEST123"}]}"#)
            }
            return Self.makeResponse(url: url, body: Self.legacyUsagePageHTML, contentType: "text/html")
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            now: Self.now,
            includeZenBalance: false,
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 17)
        #expect(snapshot.weeklyUsagePercent == 75)
        #expect(requests.values.contains("/_server"))
        #expect(requests.values.contains("/workspace/wrk_TEST123/go"))
    }

    /// A console timeout is not a credential problem and must not strand the legacy endpoints.
    @Test
    func `console transport failure falls back to the legacy page`() async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }

        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            requests.append(url.path)

            if url.path.hasPrefix("/console/api/") {
                throw URLError(.timedOut)
            }
            if url.path == "/_server" {
                return Self.makeResponse(url: url, body: #"{"data":[{"id":"wrk_TEST123"}]}"#)
            }
            return Self.makeResponse(url: url, body: Self.legacyUsagePageHTML, contentType: "text/html")
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=test",
            timeout: 2,
            now: Self.now,
            includeZenBalance: false,
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 17)
        #expect(requests.values.contains("/workspace/wrk_TEST123/go"))
    }

    /// Credentials are only expired once the legacy endpoints reject them too.
    @Test
    func `rejection by both console and legacy reports invalid credentials`() async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }

        ConsoleMigrationURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(url: url, body: #"{"message":"Unauthorized"}"#, statusCode: 401)
        }

        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "auth=test",
                timeout: 2,
                now: Self.now,
                includeZenBalance: false,
                session: self.makeSession())
            Issue.record("Expected OpenCodeGoUsageError.invalidCredentials")
        } catch let error as OpenCodeGoUsageError {
            guard case .invalidCredentials = error else {
                Issue.record("Expected invalidCredentials, got: \(error)")
                return
            }
        }
    }

    /// Reported by the migrated pay-as-you-go workspace in steipete/CodexBar#3783: a $27.87 balance
    /// arrives as micro-cents, the same scale the legacy billing response used.
    @Test
    func `parses the console prepaid balance`() throws {
        let payload = """
        {"billingMode":"prepaid","mode":"pay-as-you-go","balanceMicroCents":"2786781005",\
        "creditLimitMicroCents":null,"availableMicroCents":"2786781005","canPurchaseCredits":true}
        """
        let parsed = try OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(text: payload)
        let balance = try #require(parsed)
        #expect((balance - 27.86781005).magnitude < 0.000001)

        // Available credit is a different field and cannot stand in for a missing balance.
        let availableOnly = #"{"mode":"pay-as-you-go","availableMicroCents":1500000000}"#
        #expect(throws: OpenCodeGoUsageError.self) {
            try OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(text: availableOnly)
        }
        #expect(throws: OpenCodeGoUsageError.self) {
            try OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(text: #"{"mode":"none"}"#)
        }
        #expect(throws: OpenCodeGoUsageError.self) {
            try OpenCodeGoZenBalanceParser.parseConsoleBillingStatus(text: Self.consoleShellHTML)
        }
    }

    @Test
    func `zen balance reads the console billing status`() async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }

        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            requests.append(url.path)

            switch url.path {
            case "/console/api/orgs":
                return Self.makeResponse(url: url, body: #"[{"id":"wrk_TEST123","name":"Default"}]"#)
            case "/console/api/billing/status":
                return Self.makeResponse(
                    url: url,
                    body: #"{"billingMode":"prepaid","mode":"pay-as-you-go","balanceMicroCents":"2786781005"}"#)
            default:
                // A migrated workspace has no Go subscription and no legacy payload.
                return Self.makeResponse(url: url, body: Self.consoleShellHTML, contentType: "text/html")
            }
        }

        let balance = try await OpenCodeGoUsageFetcher.fetchOptionalZenBalance(
            cookieHeader: "auth=test; __Host-console_session=console456",
            timeout: 2,
            session: self.makeSession())

        let resolved = try #require(balance)
        #expect((resolved - 27.86781005).magnitude < 0.000001)
        #expect(requests.values.contains("/console/api/billing/status"))
    }

    /// Workspaces that have not migrated keep the scraped balance.
    @Test
    func `zen balance falls back to the legacy workspace page`() async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }

        ConsoleMigrationURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path.hasPrefix("/console/api/") {
                return Self.makeResponse(url: url, body: #"{"_tag":"NotFound"}"#, statusCode: 404)
            }
            if url.path == "/_server" {
                return Self.makeResponse(url: url, body: #"{"data":[{"id":"wrk_TEST123"}]}"#)
            }
            return Self.makeResponse(
                url: url,
                body: #"<html><body><h2>Current balance $98.76</h2></body></html>"#,
                contentType: "text/html")
        }

        let balance = try await OpenCodeGoUsageFetcher.fetchOptionalZenBalance(
            cookieHeader: "auth=test",
            timeout: 2,
            session: self.makeSession())

        #expect(balance == 98.76)
    }

    @Test
    func `console JSON is not misread as a signed-out page`() {
        // The console shell and its JSON payloads mention login routes; only HTTP status decides.
        #expect(OpenCodeGoUsageFetcher.parseConsoleGoStatus(text: Self.goStatusJSON(), now: Self.now) != nil)
        #expect(OpenCodeGoUsageFetcher.parseConsoleGoStatus(text: Self.consoleShellHTML, now: Self.now) == nil)
        #expect(OpenCodeGoUsageFetcher.parseConsoleGoStatus(text: #"{"access":{}}"#, now: Self.now) == nil)
    }

    @Test(arguments: [401, 403], [false, true])
    func `legacy session survives independent console authentication rejection`(
        statusCode: Int,
        workspaceOverride: Bool) async throws
    {
        defer { ConsoleMigrationURLProtocol.handler = nil }
        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            let url = try #require(request.url)
            requests.append(url.path)
            if url.path.hasPrefix("/console/api/") {
                return Self.makeResponse(url: url, body: "{}", statusCode: statusCode)
            }
            if url.path == "/_server" {
                return Self.makeResponse(url: url, body: #"[{"id":"wrk_TEST123"}]"#)
            }
            return Self.makeResponse(url: url, body: Self.legacyUsage)
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=legacy; __Host-console_session=expired",
            timeout: 2,
            workspaceIDOverride: workspaceOverride ? Self.workspaceID : nil,
            includeZenBalance: false,
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 17)
        let discovery = workspaceOverride ? [] : ["/console/api/orgs", "/_server"]
        #expect(requests.values == discovery + ["/console/api/go/status", "/workspace/wrk_TEST123/go"])
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost], [false, true])
    func `legacy reads recover from console transport errors`(
        code: URLError.Code,
        workspaceOverride: Bool) async throws
    {
        defer { ConsoleMigrationURLProtocol.handler = nil }
        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            let url = try #require(request.url)
            requests.append(url.path)
            if url.path.hasPrefix("/console/api/") { throw URLError(code) }
            if url.path == "/_server" {
                return Self.makeResponse(url: url, body: #"[{"id":"wrk_TEST123"}]"#)
            }
            return Self.makeResponse(url: url, body: Self.legacyUsage)
        }

        let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
            cookieHeader: "auth=legacy",
            timeout: 2,
            workspaceIDOverride: workspaceOverride ? Self.workspaceID : nil,
            includeZenBalance: false,
            session: self.makeSession())

        #expect(snapshot.rollingUsagePercent == 17)
        let discovery = workspaceOverride ? [] : ["/console/api/orgs", "/_server"]
        #expect(requests.values == discovery + ["/console/api/go/status", "/workspace/wrk_TEST123/go"])
    }

    @Test(arguments: [false, true])
    func `console cancellation never starts a legacy request`(workspaceOverride: Bool) async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }
        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            try requests.append(#require(request.url).path)
            throw URLError(.cancelled)
        }

        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "auth=legacy; __Host-console_session=console",
                timeout: 2,
                workspaceIDOverride: workspaceOverride ? Self.workspaceID : nil,
                includeZenBalance: false,
                session: self.makeSession())
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Cancellation can be normalized by the provider's task boundary.
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(requests.values == [workspaceOverride ? "/console/api/go/status" : "/console/api/orgs"])
    }

    @Test(arguments: [false, true])
    func `console certificate failures never start legacy requests`(workspaceOverride: Bool) async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }
        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            try requests.append(#require(request.url).path)
            throw URLError(.serverCertificateUntrusted)
        }

        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "auth=legacy; __Host-console_session=console",
                timeout: 2,
                workspaceIDOverride: workspaceOverride ? Self.workspaceID : nil,
                includeZenBalance: false,
                session: self.makeSession())
            Issue.record("Expected certificate failure")
        } catch let error as URLError {
            #expect(error.code == .serverCertificateUntrusted)
        }
        #expect(requests.values == [workspaceOverride ? "/console/api/go/status" : "/console/api/orgs"])
    }

    @Test(arguments: [false, true])
    func `console-only expired sessions do not attempt legacy authentication`(workspaceOverride: Bool) async throws {
        defer { ConsoleMigrationURLProtocol.handler = nil }
        let requests = ConsoleRequestRecorder()
        ConsoleMigrationURLProtocol.handler = { request in
            let url = try #require(request.url)
            requests.append(url.path)
            return Self.makeResponse(url: url, body: "{}", statusCode: 401)
        }

        do {
            _ = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: "__Host-console_session=expired",
                timeout: 2,
                workspaceIDOverride: workspaceOverride ? Self.workspaceID : nil,
                includeZenBalance: false,
                session: self.makeSession())
            Issue.record("Expected invalid credentials")
        } catch let error as OpenCodeGoUsageError {
            guard case .invalidCredentials = error else {
                Issue.record("Expected invalid credentials, got \(error)")
                return
            }
        }
        #expect(requests.values == [workspaceOverride ? "/console/api/go/status" : "/console/api/orgs"])
    }

    private static let legacyUsage = """
    {"rollingUsage":{"usagePercent":17,"resetInSec":5944},\
    "weeklyUsage":{"usagePercent":75,"resetInSec":278201}}
    """
}

private final class ConsoleMigrationURLProtocol: URLProtocol {
    private static let handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self.handlerBox.value }
        set { Self.handlerBox.setValue(newValue) }
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
