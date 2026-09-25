import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginOptionalRequestTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `both origins are validated before either request is sent`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(engine: engine, optionalURL: "https://undeclared.test/optional") { _ in
            Issue.record("Invalid optional origin reached transport")
            throw URLError(.badURL)
        }
        await #expect(throws: ProviderPluginError.self) { _ = try await runtime.fetchUsage() }
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["size", "compression", "status"])
    func `optional responses keep size compression and status boundaries`(
        engine: ProviderPluginEngineKind,
        failure: String) async throws
    {
        let runtime = try Self.runtime(engine: engine, limit: 8) { request in
            let optional = request.url?.path == "/optional"
            let body = optional && failure == "size" ? "more than eight bytes" : "OK"
            let code = optional && failure == "status" ? 500 : 200
            let headers = optional && failure == "compression" ? ["Content-Encoding": "gzip"] : [:]
            return try Self.response(request, body: body, status: code, headers: headers)
        }
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "none")
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["size", "compression"])
    func `required responses still reject representation failures`(
        engine: ProviderPluginEngineKind,
        failure: String) async throws
    {
        let runtime = try Self.runtime(engine: engine, limit: 8) { request in
            let primary = request.url?.path == "/primary"
            let body = primary && failure == "size" ? "more than eight bytes" : "OK"
            let headers = primary && failure == "compression" ? ["Content-Encoding": "gzip"] : [:]
            return try Self.response(request, body: body, headers: headers)
        }
        await #expect(throws: ProviderPluginError.self) { _ = try await runtime.fetchUsage() }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `slow primary keeps a secondary that completed after the collection budget`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try Self.runtime(engine: engine) { request in
            try await Task.sleep(for: request.url?.path == "/primary" ? .milliseconds(400) : .milliseconds(250))
            return try Self.response(request, body: "ready")
        }
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "ready")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `slow primary does not receive a fresh collection budget`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(engine: engine) { request in
            try await Task.sleep(for: request.url?.path == "/primary" ? .milliseconds(300) : .milliseconds(400))
            return try Self.response(request, body: "late")
        }
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "none")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `caller cancellation reaches both requests`(engine: ProviderPluginEngineKind) async throws {
        let calls = RequestCalls()
        let runtime = try Self.runtime(engine: engine) { request in
            calls.start()
            do { try await Task.sleep(for: .seconds(30)) } catch {
                calls.cancel()
                throw error
            }
            return try Self.response(request, body: "unexpected")
        }
        let task = Task { try await runtime.fetchUsage() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while calls.counts.0 < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.counts.0 == 2)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let cancelledDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while calls.counts.1 < 2, ContinuousClock.now < cancelledDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.counts.1 == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `optional transport ignoring cancellation cannot hold the result`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try Self.runtime(engine: engine) { request in
            if request.url?.path == "/optional" {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume() }
                }
            }
            return try Self.response(request, body: "late")
        }
        let start = ContinuousClock.now
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "none")
        #expect(start.duration(to: .now) < .milliseconds(800))
        try await Task.sleep(for: .milliseconds(1100))
    }

    private static func runtime(
        engine: ProviderPluginEngineKind,
        optionalURL: String = "https://example.test/optional",
        limit: Int = 1024,
        handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) throws -> ProviderPluginRuntime
    {
        try ProviderPluginRuntime(
            source: """
            defineProvider({
              id: 'optional-fixture', name: 'Optional fixture', endpoints: ['https://example.test'], settings: [],
              capabilities: ['http-status'],
              async fetchUsage(ctx) {
                const response = await ctx.http.getWithOptional('https://example.test/primary', '\(optionalURL)');
                return {identity: {loginMethod: response.optional?.bodyText || 'none'}};
              }
            });
            """,
            transport: ProviderHTTPTransportHandler(handler),
            responseSizeLimit: limit,
            enforcesUserResponsePolicy: true,
            allowsDynamicID: true,
            engine: engine)
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200,
        headers: [String: String] = [:]) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers))
        return (Data(body.utf8), response)
    }

    private final class RequestCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var cancelled = 0
        var counts: (Int, Int) {
            self.lock.withLock { (self.started, self.cancelled) }
        }

        func start() { self.lock.withLock { self.started += 1 } }
        func cancel() { self.lock.withLock { self.cancelled += 1 } }
    }
}
