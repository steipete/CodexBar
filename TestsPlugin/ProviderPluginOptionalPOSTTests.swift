import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ProviderPluginOptionalPOSTTests {
    @Test(arguments: BundledPluginTestSupport.engines, [false, true])
    func `optional POST overlaps GET with independent body headers and five second cap`(
        engine: ProviderPluginEngineKind, form: Bool) async throws
    {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let runtime = try Self.runtime(engine, optional: """
        {url: 'https://console.example.com/optional', method: 'POST',
         \(form ? "form: { token: 'fixture +&' }" : "body: { token: 'fixture' }"),
         headers: {'X-Optional': 'yes'}, timeoutSeconds: 90}
        """) { request in
            if request.httpMethod == "GET" {
                #expect(request.httpBody == nil)
                #expect(request.value(forHTTPHeaderField: "X-Optional") == nil)
                for await _ in started {
                    break
                }
            } else {
                #expect(request.timeoutInterval == 5)
                #expect(request.value(forHTTPHeaderField: "X-Optional") == "yes")
                #expect(request.value(forHTTPHeaderField: "Content-Type") ==
                    (form ? "application/x-www-form-urlencoded" : "application/json"))
                let body = try #require(String(data: request.httpBody ?? Data(), encoding: .utf8))
                #expect(form ? body == "token=fixture%20%2B%26" : body.contains("fixture"))
                continuation.yield(())
                continuation.finish()
            }
            return ProviderPluginConsoleCapabilitiesTests.response(request, body: "ready")
        }
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "ready")
    }

    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines)
    func `optional POST can collect beyond the existing GET default`(engine: ProviderPluginEngineKind) async throws {
        let (primary, primaryCollected) = AsyncStream<Void>.makeStream()
        let (deadlines, deadlineObserved) = AsyncStream<Void>.makeStream()
        let (pending, release) = AsyncStream<Void>.makeStream()
        defer {
            primaryCollected.finish()
            deadlineObserved.finish()
            release.finish()
        }
        let options = ProviderPluginContextOptions(
            optionalRequestTimeoutSeconds: nil,
            waitForOptionalDeadline: { _, budget in
                #expect(budget == .seconds(5))
                #expect(budget > ProviderPluginContextOptions.production.optionalCollectionBudget)
                deadlineObserved.yield()
                for await _ in pending {}
                try Task.checkCancellation()
            },
            beforeHTTPAttempt: { request in
                if request.httpMethod == "POST" {
                    var iterator = primary.makeAsyncIterator()
                    #expect(await iterator.next() != nil)
                    var deadline = deadlines.makeAsyncIterator()
                    #expect(await deadline.next() != nil)
                }
            },
            didCollectHTTPCompletion: { completion in
                if case .primary = completion { primaryCollected.yield() }
            })
        let runtime = try Self.runtime(engine, budget: "5", contextOptions: options) { request in
            ProviderPluginConsoleCapabilitiesTests.response(request, body: "ready")
        }
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "ready")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `optional POST failures never fail primary or retry POST`(engine: ProviderPluginEngineKind) async throws {
        let calls = Calls()
        let runtime = try Self.runtime(engine) { request in
            if request.httpMethod == "POST" {
                calls.started()
                throw URLError(.timedOut)
            }
            return ProviderPluginConsoleCapabilitiesTests.response(request, body: "ready")
        }
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "none")
        #expect(calls.count == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid optional POST origin method body and budget are refused before either request`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (optional, budget) in [
            ("{url:'https://undeclared.test/',method:'POST',body:{}}", "5"),
            ("{url:'https://console.example.com/',method:'DELETE',body:{}}", "5"),
            ("{url:'https://console.example.com/',method:'POST',form:{x:2}}", "5"),
            ("{url:'https://console.example.com/',method:'POST',form:{},body:{}}", "5"),
            ("{url:'https://console.example.com/',method:'POST',body:{}}", "6"),
            ("{url:'https://console.example.com/',method:'POST',body:{}}", "true"),
        ] {
            let runtime = try Self.runtime(engine, optional: optional, budget: budget) { _ in
                Issue.record("Invalid request reached transport")
                throw URLError(.badURL)
            }
            await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `optional form secrets are redacted even when optional transport fails`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try Self.runtime(engine, optional: """
        {url:'https://console.example.com/optional',method:'POST',form:{token:'private-fixture+&'}}
        """, suffix: "throw new Error('private-fixture+& private-fixture%2B%26');") { request in
            if request.httpMethod == "POST" { throw URLError(.cannotConnectToHost) }
            return ProviderPluginConsoleCapabilitiesTests.response(request, body: "ready")
        }
        let error = await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        #expect(error?.localizedDescription.contains("private-fixture") == false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines, [false, true])
    func `caller cancellation interrupts required GET and optional POST`(
        engine: ProviderPluginEngineKind, waitingForAdmission: Bool) async throws
    {
        try await ProviderPluginCancellationTestSupport.checkCallerCancellation(
            engine: engine, optionalMethod: "POST", waitingForAdmission: waitingForAdmission)
    }

    private static func runtime(
        _ engine: ProviderPluginEngineKind,
        optional: String = "{url:'https://console.example.com/optional',method:'POST',body:{}}",
        budget: String = "5",
        suffix: String = "return {identity:{loginMethod:response.optional?.bodyText || 'none'}};",
        contextOptions: ProviderPluginContextOptions = BundledPluginTestSupport.contextOptions,
        handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) throws -> ProviderPluginRuntime
    {
        try ProviderPluginConsoleCapabilitiesTests.runtime(engine, body: """
        const response = await ctx.http.getWithOptional('https://console.example.com/primary',
          \(optional), {optionalBudgetSeconds:\(budget)});
        \(suffix)
        """, transport: ProviderHTTPTransportHandler(handler), contextOptions: contextOptions)
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var starts = 0
        var count: Int {
            self.lock.withLock { self.starts }
        }

        func started() { self.lock.withLock { self.starts += 1 } }
    }
}
