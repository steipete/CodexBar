import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginTransportTests {
    #if canImport(JavaScriptCore)
    static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif

    @Test
    func `outer QuickJS deadline retains the native timeout code`() {
        let result = QuickJSBlockingResult<Int>()
        result.markStarted()
        #expect(throws: URLError(.timedOut)) {
            try result.value(timeout: 0, fetchDeadline: Date().addingTimeInterval(20), watchdog: nil)
        }
    }

    @Test(arguments: Self.engines)
    func `HTTP rejections preserve transport codes and retry classification`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (code, kind) in [
            (URLError.timedOut, "timeout"), (.dnsLookupFailed, "dns"), (.cannotFindHost, "dns"),
            (.notConnectedToInternet, "offline"), (.cancelled, "cancelled"),
            (.secureConnectionFailed, "tls"), (.serverCertificateUntrusted, "tls"),
            (.networkConnectionLost, "connection"), (.cannotConnectToHost, "connection"), (.badURL, "other"),
        ] {
            let runtime = try Self.runtime(
                engine,
                body: """
                try { await ctx.http.get('https://example.com'); } catch (error) {
                  return { identity: { loginMethod: JSON.stringify({
                    isError: error instanceof Error, code: error.transportCode,
                    kind: error.transportClass, retryable: error.retryable
                  }) } };
                }
                """,
                transport: ProviderHTTPTransportHandler { _ in throw URLError(code) })
            let usage = try await runtime.fetchUsage()
            let label = try #require(usage.identity?.loginMethod)
            let fields = try #require(JSONSerialization.jsonObject(with: Data(label.utf8)) as? [String: Any])
            #expect(fields["isError"] as? Bool == true)
            #expect(fields["code"] as? Int == code.rawValue)
            #expect(fields["kind"] as? String == kind)
            #expect(fields["retryable"] as? Bool == ProviderHTTPRetryPolicy.transientIdempotent
                .retryableURLErrorCodes.contains(code))
        }
    }

    @Test(arguments: Self.engines)
    func `uncaught cancellation is distinct from script failure`(engine: ProviderPluginEngineKind) async throws {
        for error: any Error in [CancellationError(), URLError(.cancelled)] {
            let runtime = try Self.runtime(
                engine,
                body: "await ctx.http.get('https://example.com');",
                transport: ProviderHTTPTransportHandler { _ in throw error })
            await #expect(throws: CancellationError.self) { try await runtime.fetchUsage() }
        }
    }

    @Test(arguments: Self.engines)
    func `opted in GET retries transient transport once`(engine: ProviderPluginEngineKind) async throws {
        let transport = PluginRetryTransport(failures: 1)
        let runtime = try Self.runtime(
            engine,
            body: """
            await ctx.http.get('https://example.com', { retryPolicy: 'transientIdempotent' });
            return { identity: { loginMethod: 'ok' } };
            """,
            transport: transport)
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "ok")
        #expect(await transport.count == 2)
    }

    @Test(arguments: Self.engines)
    func `uncaught URL errors retain their codes`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(
            engine,
            body: "await ctx.http.get('https://example.com');",
            transport: ProviderHTTPTransportHandler { _ in throw URLError(.timedOut) })
        await #expect(throws: URLError(.timedOut)) { try await runtime.fetchUsage() }
    }

    @Test(arguments: Self.engines)
    func `script properties cannot forge or change native cancellation`(engine: ProviderPluginEngineKind) async throws {
        let forged = try Self.runtime(engine, body: "throw { transportCode: -999, message: 'fixture' };")
        await #expect(throws: ProviderPluginError.script("fixture")) { try await forged.fetchUsage() }
        let mutated = try Self.runtime(
            engine,
            body: """
            try { await ctx.http.get('https://example.com'); }
            catch (error) { error.transportCode = -999; throw error; }
            """,
            transport: ProviderHTTPTransportHandler { _ in throw URLError(.timedOut) })
        await #expect(throws: URLError(.timedOut)) { try await mutated.fetchUsage() }
        let replayed = try Self.runtime(
            engine,
            body: """
            if (globalThis.previousError) throw globalThis.previousError;
            try { await ctx.http.get('https://example.com'); }
            catch (error) { globalThis.previousError = error; }
            return { identity: { loginMethod: 'ok' } };
            """,
            transport: ProviderHTTPTransportHandler { _ in throw CancellationError() })
        _ = try await replayed.fetchUsage()
        await #expect(throws: ProviderPluginError.self) { try await replayed.fetchUsage() }
    }

    @Test(arguments: Self.engines)
    func `interrupt survives a fetch that has not started`(engine: ProviderPluginEngineKind) async throws {
        let url = try #require(CodexBarCoreResources.bundle?.url(
            forResource: "provider-plugin-prelude", withExtension: "js"))
        let worker = try ProviderPluginEngineFactory.make(
            kind: engine,
            source: """
            defineProvider({ id: 'neuralwatt', name: 'Fixture', endpoints: ['https://example.com'], settings: [],
              async fetchUsage(ctx) { await ctx.http.get('https://example.com'); }
            });
            """,
            preludeSource: String(contentsOf: url, encoding: .utf8),
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("An interrupted worker must not start another request")
                throw URLError(.cancelled)
            },
            timeout: 20,
            responseSizeLimit: 1024,
            enforcesUserResponsePolicy: false,
            allowsDynamicID: false)
        worker.requestInterrupt()
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UsageSnapshot, Error>) in
                worker.fetch(
                    settings: [:],
                    secrets: [:],
                    now: Date(),
                    timeZone: .current,
                    contextOptions: .production,
                    cookieResolver: nil,
                    instanceCookieResolver: nil,
                    completion: { continuation.resume(with: $0) })
            }
        }
    }

    @Test(arguments: Self.engines)
    func `task cancellation interrupts the in flight request`(engine: ProviderPluginEngineKind) async throws {
        let (events, continuation) = AsyncStream.makeStream(of: String.self)
        let runtime = try Self.runtime(
            engine,
            body: "await ctx.http.get('https://example.com');",
            transport: ProviderHTTPTransportHandler { _ in
                continuation.yield("started")
                do { try await Task.sleep(for: .seconds(30)) } catch { continuation.yield("cancelled"); throw error }
                throw URLError(.timedOut)
            })
        var iterator = events.makeAsyncIterator()
        let task = Task { try await runtime.fetchUsage() }
        #expect(await iterator.next() == "started")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await iterator.next() == "cancelled")
        continuation.finish()
    }

    @Test(arguments: Self.engines)
    func `fetch deadline bounds attempts waiting to start`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(
            engine,
            body: "await ctx.http.get('https://example.com', { timeoutSeconds: 1 });",
            timeout: 0.2,
            contextOptions: ProviderPluginContextOptions(
                optionalRequestTimeoutSeconds: nil,
                beforeHTTPAttempt: { try await Task.sleep(for: .seconds(30)) }),
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("Transport must not run after the fetch deadline")
                throw URLError(.badURL)
            })
        await #expect {
            try await runtime.fetchUsage()
        } throws: { error in
            // The QuickJS fetch deadline and the runtime watchdog can win the same race.
            (error as? ProviderPluginError) == .timedOut || (error as? URLError)?.code == .timedOut
        }
    }

    @Test(arguments: Self.engines)
    func `cancellation interrupts an attempt waiting to start`(engine: ProviderPluginEngineKind) async throws {
        let (events, continuation) = AsyncStream<String>.makeStream()
        defer { continuation.finish() }
        let runtime = try Self.runtime(
            engine,
            body: "await ctx.http.get('https://example.com');",
            contextOptions: ProviderPluginContextOptions(
                optionalRequestTimeoutSeconds: nil,
                beforeHTTPAttempt: {
                    continuation.yield("waiting")
                    do { try await Task.sleep(for: .seconds(30)) } catch {
                        continuation.yield("cancelled")
                        throw error
                    }
                }),
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("Transport must not run after cancellation")
                throw URLError(.badURL)
            })
        var iterator = events.makeAsyncIterator()
        let task = Task { try await runtime.fetchUsage() }
        #expect(await iterator.next() == "waiting")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await iterator.next() == "cancelled")
    }

    @Test(arguments: Self.engines)
    func `failure before attempt start preserves its original error`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(
            engine,
            body: "await ctx.http.get('https://example.com');",
            contextOptions: ProviderPluginContextOptions(
                optionalRequestTimeoutSeconds: nil,
                beforeHTTPAttempt: { throw URLError(.badURL) }))
        await #expect(throws: URLError(.badURL)) { try await runtime.fetchUsage() }
    }

    @Test(arguments: Self.engines)
    func `retry exhaustion defaults and POST keep their request bounds`(engine: ProviderPluginEngineKind) async throws {
        for (call, count) in [
            ("get('https://example.com')", 1),
            ("get('https://example.com', { retryPolicy: 'transientIdempotent' })", 2),
            ("post('https://example.com', { body: {}, retryPolicy: 'transientIdempotent' })", 1),
        ] {
            let transport = PluginRetryTransport(failures: 3)
            let runtime = try Self.runtime(engine, body: "await ctx.http.\(call);", transport: transport)
            await #expect(throws: URLError(.timedOut)) { try await runtime.fetchUsage() }
            #expect(await transport.count == count)
        }
    }

    @Test(arguments: Self.engines)
    func `native Retry After is capped at ten seconds`(engine: ProviderPluginEngineKind) async throws {
        let transport = PluginStatusTransport(status: 429, retryAfter: "3600", recovers: true)
        let runtime = try Self.runtime(
            engine,
            body: """
            await ctx.http.get('https://example.com', { retryPolicy: 'transientIdempotent' });
            return { identity: { loginMethod: 'ok' } };
            """,
            transport: transport)
        let start = ContinuousClock.now
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "ok")
        #expect(start.duration(to: .now) >= .seconds(10))
        #expect(await transport.count == 2)
    }

    @Test(arguments: Self.engines)
    func `request deadline applies to each retry attempt`(engine: ProviderPluginEngineKind) async throws {
        let counter = PluginStatusTransport(status: 200)
        let runtime = try Self.runtime(
            engine,
            body: """
            await ctx.http.get('https://example.com', { timeoutSeconds: 1, retryPolicy: 'transientIdempotent' });
            return { identity: { loginMethod: 'ok' } };
            """,
            transport: ProviderHTTPTransportHandler { request in
                let response = try await counter.data(for: request)
                try await Task.sleep(for: .seconds(5))
                return response
            })
        await #expect(throws: URLError(.timedOut)) { try await runtime.fetchUsage() }
        #expect(await counter.count == 2)
    }

    @Test(arguments: Self.engines)
    func `offline and TLS failures do not retry`(engine: ProviderPluginEngineKind) async throws {
        for code in [URLError.notConnectedToInternet, .secureConnectionFailed, .cancelled] {
            let transport = PluginRetryTransport(failures: 3, code: code)
            let runtime = try Self.runtime(
                engine,
                body: """
                await ctx.http.get('https://example.com', { retryPolicy: 'transientIdempotent' });
                """,
                transport: transport)
            do { _ = try await runtime.fetchUsage(); Issue.record("Expected failure") } catch {
                #expect(error is URLError || error is CancellationError)
            }
            #expect(await transport.count == 1)
        }
    }

    @Test(arguments: Self.engines)
    func `cancellation stops a pending retry delay`(engine: ProviderPluginEngineKind) async throws {
        let (events, continuation) = AsyncStream.makeStream(of: Void.self)
        let transport = PluginStatusTransport(status: 429, retryAfter: "10")
        let runtime = try Self.runtime(
            engine,
            body: """
            await ctx.http.get('https://example.com', { retryPolicy: 'transientIdempotent' });
            """,
            transport: ProviderHTTPTransportHandler { request in
                let response = try await transport.data(for: request)
                continuation.yield()
                return response
            })
        var iterator = events.makeAsyncIterator()
        let task = Task { try await runtime.fetchUsage() }
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.count == 1)
        continuation.finish()
    }

    static func runtime(
        _ engine: ProviderPluginEngineKind,
        body: String,
        enforcesUserResponsePolicy: Bool = false,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        contextOptions: ProviderPluginContextOptions = .production,
        transport: any ProviderHTTPTransport = ProviderHTTPTransportHandler { _ in throw URLError(.badURL) }) throws
        -> ProviderPluginRuntime
    {
        try ProviderPluginRuntime(
            source: """
            defineProvider({ id: 'neuralwatt', name: 'Fixture', endpoints: ['https://example.com'], settings: [],
              async fetchUsage(ctx) { \(body) }
            });
            """,
            resourceBundle: CodexBarCoreResources.bundle,
            transport: transport,
            timeout: timeout,
            enforcesUserResponsePolicy: enforcesUserResponsePolicy,
            contextOptions: contextOptions,
            engine: engine)
    }

    @Test(arguments: Self.engines)
    func `HTTP rejection carries status and transient eligibility`(engine: ProviderPluginEngineKind) async throws {
        for status in [401, 429, 503] {
            let runtime = try Self.runtime(
                engine,
                body: """
                try { await ctx.http.get('https://example.com'); } catch (error) {
                  return { identity: { loginMethod: [error.transportClass, error.status, error.retryable].join(':') } };
                }
                """,
                enforcesUserResponsePolicy: true,
                transport: PluginStatusTransport(status: status))
            #expect(try await runtime.fetchUsage().identity?.loginMethod == "http:\(status):\(status != 401)")
        }
    }

    @Test(arguments: Self.engines)
    func `native status retry is not replayed by the fetch pipeline`(engine: ProviderPluginEngineKind) async throws {
        for status in [408, 429, 500, 502, 503, 504, 401, 501] {
            let transport = PluginStatusTransport(status: status)
            let runtime = try Self.runtime(
                engine,
                body: """
                await ctx.http.get('https://example.com', { retryPolicy: 'transientIdempotent' });
                """,
                enforcesUserResponsePolicy: true,
                transport: transport)
            await #expect(throws: ProviderPluginError.self) {
                try await ProviderFetchDelayedRetry.run { try await runtime.fetchUsage() }
            }
            #expect(await transport.count == ([401, 501].contains(status) ? 1 : 2))
        }
    }
}

private actor PluginStatusTransport: ProviderHTTPTransport {
    let status: Int
    let retryAfter: String
    let recovers: Bool
    private(set) var count = 0

    init(status: Int, retryAfter: String = "0", recovers: Bool = false) {
        self.status = status
        self.retryAfter = retryAfter
        self.recovers = recovers
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.count += 1
        return (Data("{}".utf8), HTTPURLResponse(
            url: request.url!,
            statusCode: self.recovers && self.count > 1 ? 200 : self.status,
            httpVersion: nil,
            headerFields: ["Retry-After": self.retryAfter])!)
    }
}

private actor PluginRetryTransport: ProviderHTTPTransport {
    private(set) var count = 0
    let failures: Int
    let code: URLError.Code

    init(failures: Int, code: URLError.Code = .timedOut) {
        self.failures = failures
        self.code = code
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.count += 1
        if self.count <= self.failures { throw URLError(self.code) }
        return (Data("{}".utf8), HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!)
    }
}
