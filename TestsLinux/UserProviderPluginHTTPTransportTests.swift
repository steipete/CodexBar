import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized)
struct UserProviderPluginHTTPTransportTests {
    @Test
    func `shared session keeps storage disabled and original timeouts`() {
        let session = UserProviderPluginHTTPClient.session
        #expect(session === UserProviderPluginHTTPClient.session)
        #expect(session.delegate is UserProviderPluginHTTPClient.Delegate)
        let configuration = session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 15)
    }

    @Test
    func `shared delegate refuses redirects`() throws {
        let session = UserProviderPluginHTTPClient.session
        let delegate = try #require(session.delegate as? UserProviderPluginHTTPClient.Delegate)
        let url = try #require(URL(string: "https://example.test/original"))
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "/redirected"]))
        let task = session.dataTask(with: url)
        defer { task.cancel() }
        let result = RedirectResult()
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: url.appendingPathComponent("redirected")))
        { request in
            result.record(request)
        }
        #expect(result.refused)
    }

    @Test
    func `per request byte caps remove successful and failed response state`() async throws {
        try await Self.withServer(handler: { _ in
            CLILocalHTTPResponse(status: .ok, body: Data(repeating: 65, count: 32768))
        }) { base in
            let limited = UserProviderPluginHTTPClient(maximumResponseBytes: 16)
            await #expect(throws: ProviderPluginError.self) {
                _ = try await limited.data(for: URLRequest(url: base))
            }
            let client = UserProviderPluginHTTPClient(maximumResponseBytes: 32768)
            let (data, _) = try await client.data(for: URLRequest(url: base))
            #expect(data.count == 32768)
            #expect(await Self.stateIsEmpty())
        }
    }

    @Test
    func `concurrent requests keep response data and byte caps separate`() async throws {
        try await Self.withServer(handler: { request in
            let body = request.path == "/small" ? "small" : String(repeating: "large", count: 100)
            return CLILocalHTTPResponse(status: .ok, body: Data(body.utf8))
        }) { base in
            let smallClient = UserProviderPluginHTTPClient(maximumResponseBytes: 5)
            let sharedClient = UserProviderPluginHTTPClient(maximumResponseBytes: 500)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<16 {
                    group.addTask {
                        let small = index.isMultiple(of: 2)
                        let client = small && index.isMultiple(of: 4) ? smallClient : sharedClient
                        let (data, _) = try await client.data(for: URLRequest(
                            url: base.appendingPathComponent(small ? "small" : "large")))
                        #expect(String(decoding: data, as: UTF8.self) == (
                            small ? "small" : String(repeating: "large", count: 100)))
                    }
                }
                try await group.waitForAll()
            }
            #expect(await Self.stateIsEmpty())
        }
    }

    @Test
    func `cancellation removes held request state and permits another request`() async throws {
        let (received, started) = AsyncStream<Void>.makeStream()
        let (held, release) = AsyncStream<Void>.makeStream()
        defer { started.finish(); release.finish() }
        try await Self.withServer(handler: { request in
            if request.path == "/held" {
                started.yield()
                for await _ in held {}
            }
            return CLILocalHTTPResponse(status: .ok, body: Data("ready".utf8))
        }) { base in
            let progress = CancellationProgress()
            let client = UserProviderPluginHTTPClient(maximumResponseBytes: 1024)
            let task = Task {
                do {
                    _ = try await client.data(for: URLRequest(url: base.appendingPathComponent("held")))
                } catch is CancellationError {
                    progress.cancelled = true
                } catch {
                    Issue.record(error)
                }
                progress.finished = true
            }
            defer { release.finish(); task.cancel() }
            var iterator = received.makeAsyncIterator()
            #expect(await iterator.next() != nil)
            #expect(UserProviderPluginHTTPClient.activeRequestCount >= 1)
            task.cancel()
            #expect(await Self.eventually { progress.finished })
            #expect(progress.cancelled)
            #expect(await Self.stateIsEmpty())
            let (data, _) = try await client.data(for: URLRequest(url: base.appendingPathComponent("next")))
            #expect(data == Data("ready".utf8))
            #expect(await Self.stateIsEmpty())
            release.finish()
            await task.value
        }
    }

    @Test
    func `pre cancelled requests do not enter the shared map`() async {
        let (start, release) = AsyncStream<Void>.makeStream()
        let gate = Task { for await _ in start {} }
        defer { release.finish() }
        let task = Task {
            await gate.value
            let client = UserProviderPluginHTTPClient(maximumResponseBytes: 1024)
            do {
                _ = try await client.data(for: URLRequest(url: URL(string: "http://127.0.0.1:1/")!))
                Issue.record("Pre-cancelled request succeeded")
            } catch {
                #expect(error is CancellationError)
            }
        }
        task.cancel()
        release.finish()
        await task.value
        #expect(await Self.stateIsEmpty())
    }

    @Test
    func `transport errors release their request state`() async throws {
        let client = UserProviderPluginHTTPClient(maximumResponseBytes: 1024)
        await #expect(throws: URLError.self) {
            _ = try await client
                .data(for: URLRequest(url: #require(URL(string: "unsupported-fixture://no-network/"))))
        }
        #expect(await Self.stateIsEmpty())
    }

    @Test
    func `successful requests do not retain their client`() async throws {
        try await Self.withServer(handler: { _ in
            CLILocalHTTPResponse(status: .ok, body: Data("ready".utf8))
        }) { base in
            weak var released: UserProviderPluginHTTPClient?
            do {
                let client = UserProviderPluginHTTPClient(maximumResponseBytes: 1024)
                released = client
                _ = try await client.data(for: URLRequest(url: base))
            }
            #expect(await Self.eventually { released == nil })
            #expect(await Self.stateIsEmpty())
        }
    }

    private static func stateIsEmpty() async -> Bool {
        await self.eventually { UserProviderPluginHTTPClient.activeRequestCount == 0 }
    }

    private static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func withServer(
        handler: @escaping CLILocalHTTPServer.Handler,
        body: (URL) async throws -> Void) async throws
    {
        let (ready, started) = AsyncStream<Void>.makeStream()
        let server = CLILocalHTTPServer(host: "127.0.0.1", port: 0, maximumConnections: 64, handler: handler)
        let running = Task { try await server.run { started.yield(); started.finish() } }
        defer { server.stop(); started.finish() }
        for await _ in ready {
            break
        }
        do {
            let port = try #require(server.listeningPort)
            try await body(URL(string: "http://127.0.0.1:\(port)/")!)
        } catch {
            server.stop()
            _ = await running.result
            throw error
        }
        server.stop()
        try await running.value
    }

    private final class CancellationProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var didFinish = false
        private var didCancel = false
        var finished: Bool {
            get { self.lock.withLock { self.didFinish } }
            set { self.lock.withLock { self.didFinish = newValue } }
        }

        var cancelled: Bool {
            get { self.lock.withLock { self.didCancel } }
            set { self.lock.withLock { self.didCancel = newValue } }
        }
    }

    private final class RedirectResult: @unchecked Sendable {
        private(set) var refused = false
        func record(_ request: URLRequest?) { self.refused = request == nil }
    }
}
