import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginOptionalRequestTests {
    @Test
    func `production optional collection budget stays at 200 milliseconds`() {
        #expect(ProviderPluginContextOptions.production.optionalCollectionBudget == .milliseconds(200))
    }

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
        let runtime = try Self.runtime(engine: engine, collectionBudget: .milliseconds(200)) { request in
            try await Task.sleep(for: request.url?.path == "/primary" ? .seconds(2) : .seconds(1))
            return try Self.response(request, body: "ready")
        }
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "ready")
    }

    @Test
    func `slow primary does not receive a fresh collection budget`() async throws {
        // Scale the shared host budget and both delays together, keeping a full second between events.
        let manifest = try Self.runtime(engine: .quickJS) { request in
            try Self.response(request, body: "unused")
        }.manifest
        let request = try ProviderPluginHTTPResponse.Request(
            rawURL: "https://example.test/primary",
            options: ["optionalURL": "https://example.test/optional"],
            method: "GET",
            settings: [:],
            secrets: [:],
            manifest: manifest,
            enforcesUserResponsePolicy: true)
        let payload = try await ProviderPluginHTTPResponse.fetch(
            request,
            transport: ProviderHTTPTransportHandler { request in
                try await Task.sleep(for: request.url?.path == "/primary" ? .seconds(3) : .seconds(4))
                return try Self.response(request, body: "late")
            },
            wantsJSON: false,
            responseSizeLimit: 1024,
            enforcesUserResponsePolicy: true,
            rejectsNonSuccessResponses: false,
            contextOptions: ProviderPluginContextOptions(
                optionalRequestTimeoutSeconds: nil,
                optionalCollectionBudget: .seconds(2)))
        #expect(payload.value["optional"] is NSNull)
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while calls.counts.0 < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.counts.0 == 2)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let cancelledDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while calls.counts.1 < 2, ContinuousClock.now < cancelledDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.counts.1 == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `optional transport ignoring cancellation cannot hold the result`(
        engine: ProviderPluginEngineKind) async throws
    {
        let calls = RequestCalls()
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let runtime = try Self.runtime(engine: engine, collectionBudget: .milliseconds(200)) { request in
            calls.start()
            if request.url?.path == "/optional" {
                // An independent task deliberately prevents caller cancellation from releasing this transport.
                await Task.detached { for await _ in release {} }.value
            }
            return try Self.response(request, body: "late")
        }
        let task = Task { try await runtime.fetchUsage() }
        switch await BoundedTaskJoin(sourceTask: task).value(joinGrace: .seconds(10)) {
        case let .value(usage):
            #expect(usage.identity?.loginMethod == "none")
            #expect(try #require(calls.elapsed) < .seconds(1))
        case .failure, .timedOut: Issue.record("Optional transport held the primary result until release")
        }
    }

    private static func runtime(
        engine: ProviderPluginEngineKind,
        optionalURL: String = "https://example.test/optional",
        limit: Int = 1024,
        collectionBudget: Duration = .seconds(3),
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
            resourceBundle: CodexBarCoreResources.bundle,
            transport: ProviderHTTPTransportHandler(handler),
            responseSizeLimit: limit,
            enforcesUserResponsePolicy: true,
            allowsDynamicID: true,
            contextOptions: ProviderPluginContextOptions(
                optionalRequestTimeoutSeconds: nil,
                optionalCollectionBudget: collectionBudget),
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
        private var startedAt: ContinuousClock.Instant?
        var elapsed: Duration? {
            self.lock.withLock { self.startedAt?.duration(to: .now) }
        }

        private var cancelled = 0
        var counts: (Int, Int) {
            self.lock.withLock { (self.started, self.cancelled) }
        }

        func start() {
            self.lock.withLock {
                self.startedAt = self.startedAt ?? .now
                self.started += 1
            }
        }

        func cancel() { self.lock.withLock { self.cancelled += 1 } }
    }
}
