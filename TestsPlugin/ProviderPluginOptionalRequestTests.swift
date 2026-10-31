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

    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines)
    func `slow primary keeps a secondary that completed after the collection budget`(
        engine: ProviderPluginEngineKind) async throws
    {
        let (budget, budgetExpired) = AsyncStream<Void>.makeStream()
        let (optional, optionalCollected) = AsyncStream<Void>.makeStream()
        defer {
            budgetExpired.finish()
            optionalCollected.finish()
        }
        let options = ProviderPluginContextOptions(
            optionalRequestTimeoutSeconds: nil,
            waitForOptionalDeadline: { _, duration in
                #expect(duration == .milliseconds(200))
            },
            beforeHTTPAttempt: { request in
                if request.url?.path == "/optional" {
                    var iterator = budget.makeAsyncIterator()
                    #expect(await iterator.next() != nil)
                }
            },
            didCollectHTTPCompletion: { completion in
                switch completion {
                case .budgetExpired: budgetExpired.yield()
                case .optional: optionalCollected.yield()
                case .primary: break
                }
            })
        let runtime = try Self.runtime(engine: engine, contextOptions: options) { request in
            if request.url?.path == "/primary" {
                var iterator = optional.makeAsyncIterator()
                #expect(await iterator.next() != nil)
            }
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
            options: ["optionalRequest": ["url": "https://example.test/optional", "method": "GET", "options": [:]]],
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

    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines, [false, true])
    func `caller cancellation reaches both requests`(
        engine: ProviderPluginEngineKind, waitingForAdmission: Bool) async throws
    {
        try await ProviderPluginCancellationTestSupport.checkCallerCancellation(
            engine: engine, optionalMethod: "GET", waitingForAdmission: waitingForAdmission)
    }

    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines, [false, true])
    func `optional transport ignoring cancellation cannot hold the result`(
        engine: ProviderPluginEngineKind, waitingForAdmission: Bool) async throws
    {
        let (starts, started) = AsyncStream<Void>.makeStream()
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let (cancellations, cancelled) = AsyncStream<Void>.makeStream()
        defer {
            started.finish()
            continuation.finish()
            cancelled.finish()
        }
        let holdOptional: @Sendable () async -> Void = {
            await withTaskCancellationHandler {
                started.yield()
                // An independent task deliberately prevents caller cancellation from releasing this transport.
                await Task.detached { for await _ in release {} }.value
            } onCancel: {
                cancelled.yield()
            }
        }
        let options = ProviderPluginContextOptions(
            optionalRequestTimeoutSeconds: nil,
            waitForOptionalDeadline: { _, budget in
                #expect(budget == .milliseconds(200))
                var iterator = starts.makeAsyncIterator()
                #expect(await iterator.next() != nil)
            },
            beforeHTTPAttempt: { request in
                // Before admission, the independent five-second request timer cannot mask a broken collection deadline.
                if waitingForAdmission, request.url?.path == "/optional" { await holdOptional() }
            })
        let runtime = try Self.runtime(engine: engine, contextOptions: options) { request in
            if !waitingForAdmission, request.url?.path == "/optional" { await holdOptional() }
            return try Self.response(request, body: "late")
        }
        let task = Task {
            let usage = try await runtime.fetchUsage()
            var iterator = cancellations.makeAsyncIterator()
            #expect(await iterator.next() != nil)
            return usage
        }
        defer { task.cancel() }
        switch await BoundedTaskJoin(sourceTask: task).value(joinGrace: .seconds(10)) {
        case let .value(usage):
            #expect(usage.identity?.loginMethod == "none")
        case .failure, .timedOut: Issue.record("Optional transport held the primary result until release")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `bounded request join cancels without waiting for an uncooperative transport or its timeout`() async {
        let (starts, started) = AsyncStream<Void>.makeStream()
        let (pending, release) = AsyncStream<Void>.makeStream()
        defer {
            started.finish()
            release.finish()
        }
        let transport = Task<Void, Error> {
            started.yield()
            await Task.detached { for await _ in pending {} }.value
        }
        // Exercise the post-admission join directly so cancellation cannot win at an earlier admission check.
        let task = Task<BoundedTaskJoinOutcome<Void>, Error> {
            await BoundedTaskJoin(sourceTask: transport).value(joinGrace: .seconds(60))
        }
        defer {
            task.cancel()
            transport.cancel()
        }
        var iterator = starts.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        task.cancel()
        switch await BoundedTaskJoin(sourceTask: task).value(joinGrace: .seconds(10)) {
        case let .value(.failure(error)): #expect(error is CancellationError)
        case .value, .failure, .timedOut: Issue.record("Request cancellation waited for the transport or its timeout")
        }
    }

    private static func runtime(
        engine: ProviderPluginEngineKind,
        optionalURL: String = "https://example.test/optional",
        limit: Int = 1024,
        contextOptions: ProviderPluginContextOptions = .init(
            optionalRequestTimeoutSeconds: nil,
            optionalCollectionBudget: .seconds(3)),
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
            contextOptions: contextOptions,
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

        func start() {
            self.lock.withLock {
                self.started += 1
            }
        }

        func cancel() { self.lock.withLock { self.cancelled += 1 } }
    }
}
