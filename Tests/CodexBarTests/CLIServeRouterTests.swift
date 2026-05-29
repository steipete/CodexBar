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

        #expect(CodexBarCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: ["requestTimeout": ["soon"]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: ["requestTimeout": ["-0.5"]],
            flags: [])) == nil)
        #expect(CodexBarCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: ["requestTimeout": ["0"]],
            flags: [])) == 0)
        #expect(CodexBarCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: ["requestTimeout": ["12.5"]],
            flags: [])) == 12.5)
        #expect(CodexBarCLI.decodeServeRequestTimeout(from: ParsedValues(
            positional: [],
            options: [:],
            flags: [])) == 30)
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

    @Test
    func `serve cache coalesces concurrent cache misses`() async {
        let cache = CLIServeResponseCache()
        let counter = ServeTestCounter()

        let responses = await withTaskGroup(of: CLILocalHTTPResponse.self) { group -> [CLILocalHTTPResponse] in
            for _ in 0..<5 {
                group.addTask {
                    await CodexBarCLI.cachedServeResponse(
                        key: "usage:",
                        cache: cache,
                        refreshInterval: 60,
                        requestTimeout: 1)
                    {
                        let call = await counter.increment()
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        return Self.response("[{\"provider\":\"codex\",\"call\":\(call)}]")
                    }
                }
            }

            var responses: [CLILocalHTTPResponse] = []
            for await response in group {
                responses.append(response)
            }
            return responses
        }

        #expect(await counter.current() == 1)
        #expect(Set(responses.map(Self.bodyString)).count == 1)
        #expect(responses.allSatisfy { $0.status == .ok })
        #expect(responses.allSatisfy { Self.bodyString($0).contains("\"call\":1") })
    }

    @Test
    func `serve cache does not cache timeouts and recovers on next success`() async {
        let cache = CLIServeResponseCache()
        let counter = ServeTestCounter()

        let timeout = await CodexBarCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 0.01)
        {
            _ = await counter.increment()
            try? await Task.sleep(nanoseconds: 200_000_000)
            return Self.response("[{\"provider\":\"codex\",\"call\":1}]")
        }

        #expect(timeout.status == .gatewayTimeout)
        #expect(Self.bodyString(timeout).contains("request timed out"))

        let success = await CodexBarCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 1)
        {
            let call = await counter.increment()
            return Self.response("[{\"provider\":\"codex\",\"call\":\(call)}]")
        }

        #expect(success.status == .ok)
        #expect(Self.bodyString(success).contains("\"call\":2"))

        let cached = await CodexBarCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 1)
        {
            let call = await counter.increment()
            return Self.response("[{\"provider\":\"codex\",\"call\":\(call)}]")
        }

        #expect(cached.status == .ok)
        #expect(Self.bodyString(cached) == Self.bodyString(success))
        #expect(await counter.current() == 2)
    }

    @Test
    func `serve cache resumes coalesced waiters on timeout`() async {
        let cache = CLIServeResponseCache()
        let counter = ServeTestCounter()

        let responses = await withTaskGroup(of: CLILocalHTTPResponse.self) { group -> [CLILocalHTTPResponse] in
            for _ in 0..<4 {
                group.addTask {
                    await CodexBarCLI.cachedServeResponse(
                        key: "usage:",
                        cache: cache,
                        refreshInterval: 60,
                        requestTimeout: 0.01)
                    {
                        _ = await counter.increment()
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        return Self.response("[{\"provider\":\"codex\"}]")
                    }
                }
            }

            var responses: [CLILocalHTTPResponse] = []
            for await response in group {
                responses.append(response)
            }
            return responses
        }

        #expect(await counter.current() == 1)
        #expect(responses.count == 4)
        #expect(responses.allSatisfy { $0.status == .gatewayTimeout })
        #expect(responses.allSatisfy { Self.bodyString($0).contains("request timed out") })
    }

    @Test
    func `serve request timeout zero disables the deadline`() async {
        let cache = CLIServeResponseCache()

        let response = await CodexBarCLI.cachedServeResponse(
            key: "usage:",
            cache: cache,
            refreshInterval: 0,
            requestTimeout: 0)
        {
            try? await Task.sleep(nanoseconds: 80_000_000)
            return Self.response("[{\"provider\":\"codex\",\"slow\":true}]")
        }

        #expect(response.status == .ok)
        #expect(Self.bodyString(response).contains("\"slow\":true"))
    }

    private static func parsedRequest(host: String) throws -> CLILocalHTTPRequest {
        let raw = "GET /usage?provider=claude HTTP/1.1\r\nHost: \(host)\r\n\r\n"
        return try CLILocalHTTPRequest.parse(Data(raw.utf8)).get()
    }

    private static func expectParseFailure(raw: String, _ expected: CLILocalHTTPRequestParseError) {
        switch CLILocalHTTPRequest.parse(Data(raw.utf8)) {
        case .success:
            Issue.record("Expected \(expected)")
        case let .failure(error):
            #expect(error == expected)
        }
    }

    private static func response(_ body: String, status: CLIHTTPStatus = .ok) -> CLILocalHTTPResponse {
        CLILocalHTTPResponse(status: status, body: Data(body.utf8))
    }

    private static func bodyString(_ response: CLILocalHTTPResponse) -> String {
        String(data: response.body, encoding: .utf8) ?? ""
    }
}

private actor ServeTestCounter {
    private var value = 0

    func increment() -> Int {
        self.value += 1
        return self.value
    }

    func current() -> Int {
        self.value
    }
}
