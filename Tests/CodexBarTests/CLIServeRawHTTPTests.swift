import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import CodexBarCLI
@testable import CodexBarCore

/// Raw-socket coverage for `codexbar serve`: boots the real `CLILocalHTTPServer` on an
/// ephemeral port, writes HTTP/1.1 bytes over a plain TCP connection, and asserts on the
/// raw response bytes. This exercises header parsing and response serialization on the
/// wire instead of calling the router or handlers directly.
///
/// Serialized: every case runs its own server whose accept loop occupies a cooperative
/// thread; running them concurrently starves the pool and stalls unrelated suites.
@Suite(.serialized)
struct CLIServeRawHTTPTests {
    @Test
    func `raw server serializes status body and extra headers on the wire`() async throws {
        try await Self.withServer(handler: { _ in
            CLILocalHTTPResponse(
                status: .ok,
                body: Data(#"{"status":"ok"}"#.utf8),
                extraHeaders: [("X-Test", "value")])
        }, body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 200 OK")
            #expect(response.headerValue("Content-Type") == "application/json; charset=utf-8")
            #expect(response.headerValue("Content-Length") == "15")
            #expect(response.headerValue("Connection") == "close")
            #expect(response.headerValue("X-Test") == "value")
            #expect(response.body == #"{"status":"ok"}"#)
        })
    }

    @Test
    func `raw server rejects non loopback host headers by default`() async throws {
        try await Self.withServer(handler: { _ in Self.okResponse() }, body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /health HTTP/1.1\r\nHost: evil.test\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 403 Forbidden")
            #expect(response.body == #"{"error":"forbidden host"}"#)
        })
    }

    @Test
    func `raw server accepts a configured non loopback host alongside loopback`() async throws {
        try await Self.withServer(
            allowedHosts: .loopbackAnd(["dashboard.local"]),
            handler: { _ in Self.okResponse() },
            body: { port in
                let allowed = try await Self.rawExchange(
                    port: port,
                    request: "GET /health HTTP/1.1\r\nHost: dashboard.local:8080\r\n\r\n")
                let loopback = try await Self.rawExchange(
                    port: port,
                    request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                let disallowed = try await Self.rawExchange(
                    port: port,
                    request: "GET /health HTTP/1.1\r\nHost: evil.test\r\n\r\n")

                #expect(allowed.statusLine == "HTTP/1.1 200 OK")
                #expect(loopback.statusLine == "HTTP/1.1 200 OK")
                #expect(disallowed.statusLine == "HTTP/1.1 403 Forbidden")
            })
    }

    @Test
    func `raw server rejects duplicate host headers`() async throws {
        try await Self.withServer(handler: { _ in Self.okResponse() }, body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nHost: localhost\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 400 Bad Request")
            #expect(response.headerValue("Cache-Control") == "no-store")
        })
    }

    @Test
    func `raw server rejects duplicate authorization headers`() async throws {
        try await Self.withServer(handler: { _ in Self.okResponse() }, body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: [
                    "GET /health HTTP/1.1",
                    "Host: 127.0.0.1",
                    "Authorization: Bearer one",
                    "Authorization: Bearer two",
                    "",
                    "",
                ].joined(separator: "\r\n"))

            #expect(response.statusLine == "HTTP/1.1 400 Bad Request")
            #expect(response.body == #"{"error":"invalid request"}"#)
            #expect(response.headerValue("Cache-Control") == "no-store")
        })
    }

    @Test
    func `raw server passes the authorization header to the handler`() async throws {
        try await Self.withServer(handler: { request in
            CLILocalHTTPResponse(
                status: .ok,
                body: Data((request.authorization ?? "none").utf8),
                contentType: "text/plain")
        }, body: { port in
            let withHeader = try await Self.rawExchange(
                port: port,
                request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret\r\n\r\n")
            let withoutHeader = try await Self.rawExchange(
                port: port,
                request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

            #expect(withHeader.body == "Bearer secret")
            #expect(withoutHeader.body == "none")
        })
    }

    // MARK: - Dashboard snapshot auth (production handler)

    @Test
    func `snapshot without credentials returns 401 with challenge and no-store`() async throws {
        try await Self.withServeRuntime(token: "secret", body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /dashboard/v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 401 Unauthorized")
            #expect(response.headerValue("WWW-Authenticate") == "Bearer")
            #expect(response.headerValue("Cache-Control") == "no-store")
            #expect(response.body == #"{"error":"unauthorized"}"#)
        })
    }

    @Test
    func `snapshot with wrong token returns 401`() async throws {
        try await Self.withServeRuntime(token: "secret", body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /dashboard/v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer wrong\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 401 Unauthorized")
            #expect(response.headerValue("WWW-Authenticate") == "Bearer")
            #expect(response.headerValue("Cache-Control") == "no-store")
        })
    }

    @Test
    func `snapshot with correct token returns decodable JSON with no-store`() async throws {
        try await Self.withServeRuntime(token: "secret", body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /dashboard/v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer secret\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 200 OK")
            #expect(response.headerValue("Cache-Control") == "no-store")
            #expect(response.headerValues("Cache-Control").count == 1)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
            #expect(object["schemaVersion"] as? Int == 1)
            #expect((object["providers"] as? [Any])?.isEmpty == true)
            #expect(object["host"] is [String: Any])
        })
    }

    @Test
    func `snapshot never accepts the token from the query string`() async throws {
        try await Self.withServeRuntime(token: "secret", body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /dashboard/v1/snapshot?token=secret HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 401 Unauthorized")
            #expect(response.headerValue("Cache-Control") == "no-store")
        })
    }

    @Test
    func `snapshot with duplicate authorization headers returns 400`() async throws {
        try await Self.withServeRuntime(token: "secret", body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: [
                    "GET /dashboard/v1/snapshot HTTP/1.1",
                    "Host: 127.0.0.1",
                    "Authorization: Bearer secret",
                    "Authorization: Bearer secret",
                    "",
                    "",
                ].joined(separator: "\r\n"))

            #expect(response.statusLine == "HTTP/1.1 400 Bad Request")
            #expect(response.headerValue("Cache-Control") == "no-store")
        })
    }

    @Test
    func `snapshot rejects non get methods with 405`() async throws {
        try await Self.withServeRuntime(token: "secret", body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "POST /dashboard/v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer secret\r\nContent-Length: 0\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 405 Method Not Allowed")
            #expect(response.headerValue("Cache-Control") == "no-store")
        })
    }

    @Test
    func `dashboard missing routes return no-store`() async throws {
        try await Self.withServeRuntime(token: "secret", body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /dashboard/v1/missing HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 404 Not Found")
            #expect(response.headerValue("Cache-Control") == "no-store")
        })
    }

    @Test
    func `snapshot fails closed when no token is configured`() async throws {
        try await Self.withServeRuntime(token: nil, body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /dashboard/v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer anything\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 401 Unauthorized")
            #expect(response.headerValue("Cache-Control") == "no-store")
        })
    }

    @Test
    func `usage and cost responses carry no-store on the wire`() async throws {
        try await Self.withServeRuntime(token: nil, body: { port in
            let usage = try await Self.rawExchange(
                port: port,
                request: "GET /usage HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            let cost = try await Self.rawExchange(
                port: port,
                request: "GET /cost HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

            #expect(usage.statusLine == "HTTP/1.1 200 OK")
            #expect(usage.headerValue("Cache-Control") == "no-store")
            #expect(usage.headerValues("Cache-Control").count == 1)
            // All providers are disabled in this runtime, so /cost rejects the request,
            // but even error responses on account-data routes stay uncacheable.
            #expect(cost.statusLine == "HTTP/1.1 400 Bad Request")
            #expect(cost.headerValue("Cache-Control") == "no-store")
        })
    }

    @Test
    func `non-loopback binds gate usage and cost behind the token`() async throws {
        try await Self.withServeRuntime(token: "secret", bindHost: "0.0.0.0", body: { port in
            let usageDenied = try await Self.rawExchange(
                port: port,
                request: "GET /usage HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            let costDenied = try await Self.rawExchange(
                port: port,
                request: "GET /cost HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            let usageAllowed = try await Self.rawExchange(
                port: port,
                request: "GET /usage HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer secret\r\n\r\n")
            let health = try await Self.rawExchange(
                port: port,
                request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

            #expect(usageDenied.statusLine == "HTTP/1.1 401 Unauthorized")
            #expect(usageDenied.headerValue("WWW-Authenticate") == "Bearer")
            #expect(usageDenied.headerValue("Cache-Control") == "no-store")
            #expect(costDenied.statusLine == "HTTP/1.1 401 Unauthorized")
            #expect(costDenied.headerValue("Cache-Control") == "no-store")
            #expect(usageAllowed.statusLine == "HTTP/1.1 200 OK")
            #expect(usageAllowed.headerValue("Cache-Control") == "no-store")
            // /health carries no account data and stays open for liveness probes.
            #expect(health.statusLine == "HTTP/1.1 200 OK")
        })
    }

    @Test
    func `dashboard error responses carry no-store`() async throws {
        try await Self.withServeRuntime(token: "secret", rawConfigJSON: "{not json", body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /dashboard/v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer secret\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 500 Internal Server Error")
            #expect(response.headerValue("Cache-Control") == "no-store")
            #expect(response.headerValues("Cache-Control").count == 1)
        })
    }

    @Test
    func `health stays open when a dashboard token is configured`() async throws {
        try await Self.withServeRuntime(token: "secret", body: { port in
            let response = try await Self.rawExchange(
                port: port,
                request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

            #expect(response.statusLine == "HTTP/1.1 200 OK")
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
            #expect(object["status"] as? String == "ok")
        })
    }

    @Test
    func `snapshot response preserves usage cache metadata`() async throws {
        let store = testConfigStore(suiteName: "CLIServeRawHTTPTests-\(UUID().uuidString)")
        defer { try? store.deleteIfPresent() }
        try store.save(CodexBarConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0, enabled: false)
        }))
        let runtime = ServeRuntime(
            configStore: store,
            cache: CLIServeResponseCache(),
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: 60,
            requestTimeout: 5,
            healthVersion: "0.0.0-test",
            dashboardAuth: CLIServeDashboardAuth(bearer: "secret"),
            bindHost: "127.0.0.1")
        let request = CLILocalHTTPRequest(
            method: "GET",
            target: "/dashboard/v1/snapshot",
            host: "127.0.0.1",
            path: "/dashboard/v1/snapshot",
            queryItems: [:],
            authorization: "Bearer secret")

        let response = await CodexBarCLI.handleServeRequest(request, runtime: runtime)

        #expect(response.status == .ok)
        #expect(response.usageCacheKeys != nil)
        #expect(response.usageCacheKeys?.isEmpty == true)
    }

    // MARK: - Harness

    /// Boots the production serve handler with an isolated config store whose providers
    /// are all disabled, so snapshot fetches stay local while the full route/auth/cache
    /// path is exercised end to end.
    ///
    /// `bindHost` configures the runtime exactly as `runServe` would for that bind
    /// host (a non-loopback value gates every data route); the test listener itself
    /// always binds loopback. `rawConfigJSON` replaces the stored config with raw
    /// bytes to provoke config-load failures.
    static func withServeRuntime(
        token: String?,
        bindHost: String = "127.0.0.1",
        rawConfigJSON: String? = nil,
        body: (UInt16) async throws -> Void) async throws
    {
        let store = testConfigStore(suiteName: "CLIServeRawHTTPTests-\(UUID().uuidString)")
        defer { try? store.deleteIfPresent() }
        try store.save(CodexBarConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0, enabled: false)
        }))
        if let rawConfigJSON {
            try Data(rawConfigJSON.utf8).write(to: store.fileURL)
        }

        let runtime = ServeRuntime(
            configStore: store,
            cache: CLIServeResponseCache(),
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: 60,
            requestTimeout: 5,
            healthVersion: "0.0.0-test",
            dashboardAuth: CLIServeDashboardAuth(bearer: token),
            bindHost: bindHost)
        try await Self.withServer(
            handler: { request in
                await CodexBarCLI.handleServeRequest(request, runtime: runtime)
            },
            body: body)
    }

    static func okResponse() -> CLILocalHTTPResponse {
        CLILocalHTTPResponse(status: .ok, body: Data(#"{"status":"ok"}"#.utf8))
    }

    /// Runs `body` against a live server bound to an ephemeral loopback port.
    static func withServer(
        allowedHosts: CLILocalHTTPAllowedHosts = .loopbackOnly,
        handler: @escaping CLILocalHTTPServer.Handler,
        body: (UInt16) async throws -> Void) async throws
    {
        let listening = RawHTTPListeningSignal()
        let server = CLILocalHTTPServer(
            host: "127.0.0.1",
            port: 0,
            allowedHosts: allowedHosts,
            handler: handler)
        let task = Task {
            try await server.run {
                listening.signal()
            }
        }

        await listening.wait()
        do {
            let port = try #require(server.listeningPort)
            try await body(port)
        } catch {
            server.stop()
            _ = try? await task.value
            throw error
        }
        server.stop()
        try await task.value
    }

    struct RawHTTPResponse {
        let statusLine: String
        let headers: [(String, String)]
        let body: String

        func headerValue(_ name: String) -> String? {
            self.headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }

        func headerValues(_ name: String) -> [String] {
            self.headers.filter { $0.0.lowercased() == name.lowercased() }.map(\.1)
        }
    }

    enum RawHTTPExchangeError: Error {
        case connectFailed
        case sendFailed
        case malformedResponse
    }

    /// Writes `request` bytes over a fresh TCP connection and reads the raw response to EOF.
    /// Runs on a Dispatch thread so the blocking socket calls cannot starve the cooperative
    /// pool the server's accept loop and handler tasks run on.
    static func rawExchange(port: UInt16, request: String) async throws -> RawHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    try Self.performRawExchange(port: port, request: request)
                })
            }
        }
    }

    private static func performRawExchange(port: UInt16, request: String) throws -> RawHTTPResponse {
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw RawHTTPExchangeError.connectFailed }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw RawHTTPExchangeError.connectFailed
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw RawHTTPExchangeError.connectFailed }

        let requestData = Data(request.utf8)
        let sent = requestData.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return -1 }
            var total = 0
            while total < requestData.count {
                let count = send(fd, base.advanced(by: total), requestData.count - total, 0)
                guard count > 0 else { return -1 }
                total += count
            }
            return total
        }
        guard sent == requestData.count else { throw RawHTTPExchangeError.sendFailed }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bufferSize = buffer.count
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                recv(fd, rawBuffer.baseAddress, bufferSize, 0)
            }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }

        return try Self.parseRawResponse(data)
    }

    private static func parseRawResponse(_ data: Data) throws -> RawHTTPResponse {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<separator.lowerBound], encoding: .utf8)
        else {
            throw RawHTTPExchangeError.malformedResponse
        }
        let body = String(data: data[separator.upperBound...], encoding: .utf8) ?? ""

        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw RawHTTPExchangeError.malformedResponse }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw RawHTTPExchangeError.malformedResponse }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        return RawHTTPResponse(statusLine: statusLine, headers: headers, body: body)
    }
}

private final class RawHTTPListeningSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignaled = false

    func signal() {
        let continuation = self.lock.withLock {
            self.isSignaled = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = self.lock.withLock {
                guard !self.isSignaled else { return true }
                self.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}
