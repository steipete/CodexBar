import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIServeRouterTests {
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
    }

    @Test
    func `local request parser preserves host header`() throws {
        let raw = """
        GET /usage?provider=codex HTTP/1.1\r
        Host: 127.0.0.1:8080\r
        User-Agent: test\r
        \r
        """
        let request = try #require(CLILocalHTTPRequest.parse(Data(raw.utf8)))

        #expect(request.path == "/usage")
        #expect(request.queryItems["provider"] == "codex")
        #expect(request.headers["host"] == "127.0.0.1:8080")
        #expect(request.headers["user-agent"] == "test")
    }

    @Test
    func `local request parser rejects duplicate host headers`() {
        let raw = """
        GET /usage HTTP/1.1\r
        Host: attacker.example\r
        Host: 127.0.0.1\r
        \r
        """

        #expect(CLILocalHTTPRequest.parse(Data(raw.utf8)) == nil)
    }

    @Test
    func `serve host guard allows only loopback hosts`() {
        #expect(CLIServeRequestGuard.isAllowedHost("127.0.0.1"))
        #expect(CLIServeRequestGuard.isAllowedHost("127.0.0.1:8080"))
        #expect(CLIServeRequestGuard.isAllowedHost("localhost"))
        #expect(CLIServeRequestGuard.isAllowedHost("LOCALHOST:8080"))
        #expect(CLIServeRequestGuard.isAllowedHost("localhost."))
        #expect(CLIServeRequestGuard.isAllowedHost("localhost.:8080"))
        #expect(CLIServeRequestGuard.isAllowedHost("[::1]"))
        #expect(CLIServeRequestGuard.isAllowedHost("[::1]:8080"))

        #expect(!CLIServeRequestGuard.isAllowedHost(nil))
        #expect(!CLIServeRequestGuard.isAllowedHost(""))
        #expect(!CLIServeRequestGuard.isAllowedHost("attacker.example"))
        #expect(!CLIServeRequestGuard.isAllowedHost("attacker.example:8080"))
        #expect(!CLIServeRequestGuard.isAllowedHost("127.0.0.1.attacker.example"))
        #expect(!CLIServeRequestGuard.isAllowedHost("[::1].attacker.example"))
    }

    @Test
    func `serve request handler rejects forbidden or missing host before routing`() async {
        let forbidden = CLILocalHTTPRequest(
            method: "GET",
            target: "/health",
            path: "/health",
            queryItems: [:],
            headers: ["host": "attacker.example"])
        let missing = CLILocalHTTPRequest(
            method: "GET",
            target: "/health",
            path: "/health",
            queryItems: [:],
            headers: [:])

        let forbiddenResponse = await CodexBarCLI.handleServeRequest(
            forbidden,
            config: CodexBarConfig.makeDefault(),
            cache: CLIServeResponseCache(),
            refreshInterval: 0)
        let missingResponse = await CodexBarCLI.handleServeRequest(
            missing,
            config: CodexBarConfig.makeDefault(),
            cache: CLIServeResponseCache(),
            refreshInterval: 0)

        #expect(forbiddenResponse.status == .forbidden)
        #expect(missingResponse.status == .forbidden)
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
            options: [:],
            flags: [])) == 60)
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
    }
}
