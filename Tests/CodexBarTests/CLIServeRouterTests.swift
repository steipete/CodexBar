import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIServeRouterTests {
    @Test
    func `local http parser accepts only loopback host headers`() throws {
        let allowedHosts = [
            "localhost",
            "localhost.",
            "localhost:8080",
            "127.0.0.1",
            "127.0.0.1:8080",
            "[::1]",
            "[::1]:8080",
        ]

        for host in allowedHosts {
            let request = try Self.parsedRequest(host: host)
            #expect(request.host == host)
            #expect(request.path == "/usage")
        }
    }

    @Test
    func `local http parser rejects hostile missing and duplicate hosts`() {
        Self.expectParseFailure(raw: "GET /usage HTTP/1.1\r\n\r\n", .missingHost)
        Self.expectParseFailure(raw: "GET /usage HTTP/1.1\r\nHost: evil.test\r\n\r\n", .disallowedHost)
        Self.expectParseFailure(raw: "GET /usage HTTP/1.1\r\nHost: localhost, evil.test\r\n\r\n", .disallowedHost)
        Self.expectParseFailure(raw: "GET /usage HTTP/1.1\r\nHost: localhost:abc\r\n\r\n", .disallowedHost)
        Self.expectParseFailure(
            raw: "GET /usage HTTP/1.1\r\nHost: localhost\r\nHost: 127.0.0.1\r\n\r\n",
            .duplicateHost)
    }

    @Test
    func `local http parser allows non loopback host only when explicitly enabled`() throws {
        let raw = "GET /dashboard/v1/snapshot HTTP/1.1\r\nHost: 192.168.1.10:8080\r\n\r\n"

        Self.expectParseFailure(raw: raw, .disallowedHost)

        let request = try CLILocalHTTPRequest.parse(
            Data(raw.utf8),
            allowNonLoopbackHost: true).get()
        #expect(request.host == "192.168.1.10:8080")
        #expect(request.path == "/dashboard/v1/snapshot")

        Self.expectParseFailure(
            raw: "GET /usage HTTP/1.1\r\nHost: 192.168.1.10, evil.test\r\n\r\n",
            .disallowedHost,
            allowNonLoopbackHost: true)
    }

    @Test
    func `routes health usage and cost endpoints`() throws {
        #expect(try CLIServeRouter.route(method: "GET", path: "/health", queryItems: [:]) == .health)
        #expect(try CLIServeRouter.route(method: "GET", path: "/usage", queryItems: [:]) == .usage(provider: nil))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/usage",
                queryItems: ["provider": "claude"]) == .usage(provider: "claude"))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/cost",
                queryItems: ["provider": "codex"]) == .cost(provider: "codex"))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/dashboard/v1/snapshot",
                queryItems: [:]) == .dashboardSnapshot)
    }

    @Test
    func `rejects non get methods`() {
        do {
            _ = try CLIServeRouter.route(method: "POST", path: "/usage", queryItems: [:])
            Issue.record("Expected methodNotAllowed")
        } catch let error as CLIServeRouteError {
            #expect(error == .methodNotAllowed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `rejects unknown paths`() {
        do {
            _ = try CLIServeRouter.route(method: "GET", path: "/missing", queryItems: [:])
            Issue.record("Expected notFound")
        } catch let error as CLIServeRouteError {
            #expect(error == .notFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `serve numeric options reject malformed values`() {
        #expect(CodexBarCLI.decodeServePort(from: ParsedValues(
            positional: [],
            options: ["port": ["abc"]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServePort(from: ParsedValues(
            positional: [],
            options: ["port": ["0"]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServePort(from: ParsedValues(
            positional: [],
            options: ["port": ["65536"]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServePort(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == 8080)

        #expect(CodexBarCLI.decodeServeRefreshInterval(from: ParsedValues(
            positional: [],
            options: ["refreshInterval": ["later"]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServeRefreshInterval(from: ParsedValues(
            positional: [],
            options: ["refreshInterval": ["-1"]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServeRefreshInterval(from: ParsedValues(
            positional: [],
            options: ["refreshInterval": ["1e300"]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServeRefreshInterval(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == 60)
    }

    @Test
    func `serve host and dashboard options parse and validate defaults`() {
        #expect(CodexBarCLI.decodeServeHost(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == "127.0.0.1")
        #expect(CodexBarCLI.decodeServeHost(from: ParsedValues(
            positional: [],
            options: ["host": ["  "]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeDashboardToken(from: ParsedValues(
            positional: [],
            options: ["dashboardToken": [" secret "]],
            flags: [])) == "secret")
        #expect(CodexBarCLI.decodeDashboardToken(from: ParsedValues(
            positional: [],
            options: ["dashboardToken": [" "]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeDashboardIdentity(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == .redacted)
        #expect(CodexBarCLI.decodeDashboardIdentity(from: ParsedValues(
            positional: [],
            options: ["dashboardIdentity": ["FULL"]],
            flags: [])) == .full)
        #expect(CodexBarCLI.decodeDashboardIdentity(from: ParsedValues(
            positional: [],
            options: ["dashboardIdentity": ["invalid"]],
            flags: [])) == nil)

        #expect(!CLIServeSecurity.requiresDashboardToken(host: "127.0.0.1"))
        #expect(!CLIServeSecurity.requiresDashboardToken(host: "localhost"))
        #expect(CLIServeSecurity.requiresDashboardToken(host: "0.0.0.0"))
        #expect(CLIServeSecurity.requiresDashboardToken(host: "192.168.1.10"))
    }

    @Test
    func `request parser captures headers case insensitively`() throws {
        let raw = [
            "GET /dashboard/v1/snapshot HTTP/1.1",
            "Host: localhost",
            "Authorization: Bearer token",
            "X-Test: value",
            "",
            "",
        ].joined(separator: "\r\n")
        let request = try CLILocalHTTPRequest.parse(Data(raw.utf8)).get()

        #expect(request.method == "GET")
        #expect(request.path == "/dashboard/v1/snapshot")
        #expect(request.headers["authorization"] == "Bearer token")
        #expect(request.headers["x-test"] == "value")
    }

    @Test
    func `serve auth allows no token and requires matching bearer token when configured`() {
        let request = CLILocalHTTPRequest(
            method: "GET",
            target: "/dashboard/v1/snapshot",
            host: "localhost",
            path: "/dashboard/v1/snapshot",
            queryItems: [:],
            headers: ["authorization": "Bearer secret"])
        let missingHeader = CLILocalHTTPRequest(
            method: "GET",
            target: "/dashboard/v1/snapshot",
            host: "localhost",
            path: "/dashboard/v1/snapshot",
            queryItems: [:],
            headers: [:])

        #expect(CLIServeAuth(dashboardToken: nil).authorizeDataRequest(missingHeader))
        #expect(CLIServeAuth(dashboardToken: "secret").authorizeDataRequest(request))
        #expect(!CLIServeAuth(dashboardToken: "secret").authorizeDataRequest(missingHeader))
        #expect(!CLIServeAuth(dashboardToken: "secret").authorizeDataRequest(CLILocalHTTPRequest(
            method: "GET",
            target: "/dashboard/v1/snapshot",
            host: "localhost",
            path: "/dashboard/v1/snapshot",
            queryItems: [:],
            headers: ["authorization": "Bearer wrong"])))
    }

    @Test
    func `serve cache skips provider error payloads`() {
        let success = CLILocalHTTPResponse(
            status: .ok,
            body: Data(#"[{"provider":"codex","source":"local"}]"#.utf8))
        let providerError = CLILocalHTTPResponse(
            status: .ok,
            body: Data(#"[{"provider":"codex","source":"local","error":{"message":"temporary"}}]"#.utf8))
        let routeError = CLILocalHTTPResponse(
            status: .badRequest,
            body: Data(#"{"error":"bad request"}"#.utf8))

        #expect(CodexBarCLI.shouldCacheServeResponse(success))
        #expect(!CodexBarCLI.shouldCacheServeResponse(providerError))
        #expect(!CodexBarCLI.shouldCacheServeResponse(routeError))

        let dashboardSuccess = CLILocalHTTPResponse(
            status: .ok,
            body: Data(#"{"providers":[{"id":"codex","error":null}]}"#.utf8))
        let dashboardProviderError = CLILocalHTTPResponse(
            status: .ok,
            body: Data(#"{"providers":[{"id":"codex","error":{"message":"temporary"}}]}"#.utf8))

        #expect(CodexBarCLI.shouldCacheServeResponse(dashboardSuccess))
        #expect(CodexBarCLI.shouldCacheServeResponse(dashboardProviderError))
    }

    @Test
    func `dashboard snapshot cache keeps stale response while expired`() async {
        let cache = CLIServeDashboardSnapshotCache()
        let response = CLILocalHTTPResponse(status: .ok, body: Data(#"{"schemaVersion":1}"#.utf8))
        let now = Date(timeIntervalSince1970: 100)

        await cache.finishRefresh(response: response, for: "codex", ttl: 10, now: now)

        #expect(await cache.response(for: "codex", now: Date(timeIntervalSince1970: 105))?.body == response.body)
        #expect(await cache.response(for: "codex", now: Date(timeIntervalSince1970: 111)) == nil)
        #expect(await cache.staleResponse(for: "codex")?.body == response.body)
        #expect(await cache.staleResponse(for: "claude") == nil)
    }

    @Test
    func `dashboard refreshing snapshot describes enabled providers without fetching`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .codex, enabled: true),
            ProviderConfig(id: .claude, enabled: false),
        ])

        let snapshot = CodexBarCLI.makeDashboardRefreshingSnapshot(
            config: config,
            refreshInterval: 60,
            identityMode: .redacted)
        let json = try #require(CodexBarCLI.encodeJSON(snapshot, pretty: false))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(object["providers"] as? [[String: Any]])
        let provider = try #require(providers.first)
        let error = try #require(provider["error"] as? [String: Any])

        #expect(providers.count == 1)
        #expect(provider["id"] as? String == "codex")
        #expect(provider["source"] as? String == "refreshing")
        #expect(error["message"] as? String == "refreshing")
    }

    @Test
    func `serve config cache key follows enabled provider set`() {
        let initial = CodexBarConfig(providers: [
            ProviderConfig(id: .codex, enabled: true),
            ProviderConfig(id: .claude, enabled: false),
        ])
        let changed = CodexBarConfig(providers: [
            ProviderConfig(id: .codex, enabled: true),
            ProviderConfig(id: .claude, enabled: true),
        ])

        #expect(CodexBarCLI.serveConfigCacheKey(initial) == "codex")
        #expect(CodexBarCLI.serveConfigCacheKey(changed) == "codex,claude")
    }

    private static func parsedRequest(host: String) throws -> CLILocalHTTPRequest {
        let raw = "GET /usage?provider=claude HTTP/1.1\r\nHost: \(host)\r\n\r\n"
        return try CLILocalHTTPRequest.parse(Data(raw.utf8)).get()
    }

    private static func expectParseFailure(
        raw: String,
        _ expected: CLILocalHTTPRequestParseError,
        allowNonLoopbackHost: Bool = false)
    {
        switch CLILocalHTTPRequest.parse(Data(raw.utf8), allowNonLoopbackHost: allowNonLoopbackHost) {
        case .success:
            Issue.record("Expected \(expected)")
        case let .failure(error):
            #expect(error == expected)
        }
    }
}
