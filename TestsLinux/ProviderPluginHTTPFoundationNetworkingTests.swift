#if os(Linux)
import Foundation
import FoundationNetworking
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Exercise the shipped transport, without URLProtocol stubs or a synthetic onCancel.
@Suite(.serialized)
struct ProviderPluginHTTPFoundationNetworkingTests {
    enum Interruption: String, CaseIterable, Sendable {
        case deadline
        case callerCancellation
    }

    @Test(arguments: Interruption.allCases)
    func `production HTTP returns while FoundationNetworking cancellation is blocked`(
        interruption: Interruption) async throws
    {
        let progress = Progress()
        let gate = SessionQueueGate(progress: progress)
        let fixture = Fixture(progress: progress)
        let server = Task { try await fixture.server.run { progress.mark("listening") } }
        let session = Self.session(gate: gate)
        let transport = ObservedTransport(session: session, progress: progress)
        let (deadlines, deadline) = AsyncStream<Void>.makeStream()
        defer {
            gate.release.signal()
            deadline.finish()
            session.invalidateAndCancel()
            fixture.release.finish()
            fixture.server.stop()
        }
        var caller: Task<Void, Never>?
        var queueBlocker: Task<Void, Never>?
        do {
            try #require(await progress.waitFor("listening"))
            let request = try fixture.request()
            let wait: @Sendable (Duration) async throws -> Void = { _ in
                progress.mark("joined")
                for await _ in deadlines {}
                try Task.checkCancellation()
            }
            let task = Task {
                do {
                    _ = try await BoundedTaskJoinTiming.$sleep.withValue(wait) {
                        try await ProviderPluginHTTPResponse.response(
                            for: request, transport: transport, retryPolicy: .disabled)
                    }
                    progress.mark("unexpectedSuccess")
                } catch {
                    if error is CancellationError { progress.mark("cancelled") }
                    if (error as? URLError)?.code == .timedOut { progress.mark("timedOut") }
                    progress.mark("finished")
                }
            }
            caller = task
            try #require(await progress.waitFor("joined"))
            try #require(await progress.waitFor("received"))
            let blockingRequest = try fixture.request(path: "/queue-hold")
            let client = ProviderHTTPClient(session: session)
            queueBlocker = Task { _ = try? await client.data(for: blockingRequest) }
            try #require(await progress.waitFor("queueHeld"))
            #expect(progress.count("received") == 1)
            #expect(!progress.contains("transportFinished"))
            let interruptedAt = ContinuousClock.now
            switch interruption {
            case .deadline:
                deadline.finish()
            case .callerCancellation:
                DispatchQueue.global().async {
                    task.cancel()
                    progress.mark("cancelReturned")
                }
            }
            #expect(await progress.waitFor("finished"), "HTTP caller waited for the held URLSession queue")
            if interruption == .callerCancellation {
                #expect(await progress.waitFor("cancelReturned"), "Cancelling the HTTP caller blocked")
            }
            #expect(progress.contains(interruption == .deadline ? "timedOut" : "cancelled"))
            #expect(!progress.contains("unexpectedSuccess"))
            #expect(!progress.contains("queueReleased"))
            #expect(!progress.contains("transportFinished"))
            print("HTTP \(interruption.rawValue): on-wire=\(progress.count("received")) " +
                "caller-finished=\(progress.contains("finished")) " +
                "cancel-returned=\(progress.contains("cancelReturned")) " +
                "session-queue-held=\(!progress.contains("queueReleased")) " +
                "elapsed=\(interruptedAt.duration(to: .now))")
        } catch is ExpectationFailedError {
            // #require already recorded the setup failure.
        } catch {
            Issue.record(error)
        }
        // Release before cancelling or invalidating; join every owned task on failure too.
        gate.release.signal()
        deadline.finish()
        caller?.cancel()
        await caller?.value
        if progress.count("sent") > 0 {
            #expect(await progress.waitFor("transportFinished"))
        }
        #expect(!progress.contains("queueHangGuard"))
        if progress.contains("queueHeld") { #expect(progress.contains("transportCancelled")) }
        fixture.release.finish()
        await queueBlocker?.value
        if progress.contains("queueHeld") {
            // The same production client/session can make a fresh request after the hold is released.
            let recovered = try await ProviderPluginHTTPResponse.response(
                for: fixture.request(path: "/recovered"), transport: transport, retryPolicy: .disabled)
            #expect(recovered.statusCode == 200)
            #expect(recovered.data == Data(#"{"ok":true}"#.utf8))
        }
        session.finishTasksAndInvalidate()
        fixture.server.stop()
        try await server.value
    }

    @Test
    func `cancellation during admission prevents a production HTTP send`() async throws {
        let progress = Progress()
        let fixture = Fixture(progress: progress)
        let server = Task { try await fixture.server.run { progress.mark("listening") } }
        let session = Self.session()
        let (admissions, admission) = AsyncStream<Void>.makeStream()
        let releaseAdmission = Task.detached { for await _ in admissions {} }
        defer {
            admission.finish()
            session.invalidateAndCancel()
            fixture.release.finish()
            fixture.server.stop()
        }
        var caller: Task<Void, Never>?
        do {
            try #require(await progress.waitFor("listening"))
            let request = try fixture.request()
            let task = Task {
                do {
                    _ = try await ProviderPluginHTTPResponse.response(
                        for: request,
                        transport: ObservedTransport(session: session, progress: progress),
                        retryPolicy: .disabled,
                        beforeAttempt: { _ in
                            await withTaskCancellationHandler {
                                progress.mark("admitted")
                                await releaseAdmission.value
                            } onCancel: {
                                progress.mark("admissionCancelled")
                            }
                        })
                    progress.mark("unexpectedSuccess")
                } catch {
                    if error is CancellationError { progress.mark("cancelled") }
                    progress.mark("finished")
                }
            }
            caller = task
            try #require(await progress.waitFor("admitted"))
            DispatchQueue.global().async {
                task.cancel()
                progress.mark("cancelReturned")
            }
            #expect(await progress.waitFor("cancelReturned"))
            #expect(await progress.waitFor("finished"))
            #expect(progress.contains("cancelled"))
            try #require(await progress.waitFor("admissionCancelled"))
        } catch is ExpectationFailedError {
            // #require already recorded the setup failure.
        } catch {
            Issue.record(error)
        }
        admission.finish()
        await releaseAdmission.value
        caller?.cancel()
        await caller?.value
        if progress.contains("admitted") {
            // The sole transport must be released before asserting that no delayed send remains.
            #expect(await progress.waitFor("transportDrained"))
            #expect(progress.count("sent") == 0)
            #expect(progress.count("received") == 0)
            #expect(!progress.contains("unexpectedSuccess"))
            let recovered = try await ProviderPluginHTTPResponse.response(
                for: fixture.request(path: "/recovered"),
                transport: ObservedTransport(session: session, progress: progress),
                retryPolicy: .disabled)
            #expect(recovered.statusCode == 200)
            #expect(progress.count("sent") == 1)
            #expect(progress.count("received") == 1)
            print("HTTP admission: cancelled=true source-drained=true cancelled-request-sends=0 recovery=200")
        }
        session.finishTasksAndInvalidate()
        fixture.server.stop()
        try await server.value
    }

    private static func session(gate: SessionQueueGate? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = gate
        return URLSession(configuration: configuration)
    }

    private struct Fixture {
        let server: CLILocalHTTPServer
        let release: AsyncStream<Void>.Continuation

        init(progress: Progress) {
            let (responses, release) = AsyncStream<Void>.makeStream()
            self.release = release
            self.server = CLILocalHTTPServer(host: "127.0.0.1", port: 0) { request in
                #expect(request.authorization == nil)
                progress.mark("received")
                if request.path == "/held" { for await _ in responses {} }
                return CLILocalHTTPResponse(
                    status: .ok,
                    body: Data(#"{"ok":true}"#.utf8),
                    extraHeaders: [("Cache-Control", "no-store")])
            }
        }

        func request(path: String = "/held") throws -> URLRequest {
            let port = try #require(self.server.listeningPort)
            let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
            var request = URLRequest(url: url)
            request.timeoutInterval = 60 // The manually fired join deadline must win, not the socket timeout.
            return request
        }
    }

    private final class ObservedTransport: ProviderHTTPTransport, @unchecked Sendable {
        private let client: ProviderHTTPClient
        private let progress: Progress

        init(session: URLSession, progress: Progress) {
            self.client = ProviderHTTPClient(session: session)
            self.progress = progress
        }

        deinit { self.progress.mark("transportDrained") }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.progress.mark("sent")
            defer { self.progress.mark("transportFinished") }
            do {
                return try await self.client.data(for: request)
            } catch {
                if (error as? URLError)?.code == .cancelled { self.progress.mark("transportCancelled") }
                throw error
            }
        }
    }

    /// FoundationNetworking 6.3.3 looks up its cache inside task.resume's workQueue.sync.
    /// A second request holds this public hook after the tested request is already on wire.
    /// The real URLSessionTask.cancel() then waits for that session queue; no cancellation
    /// handler, URLProtocol, session method, or transport implementation is replaced.
    private final class SessionQueueGate: URLCache, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        private let progress: Progress

        init(progress: Progress) {
            self.progress = progress
            super.init(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
        }

        override func getCachedResponse(
            for dataTask: URLSessionDataTask,
            completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void)
        {
            if dataTask.originalRequest?.url?.path == "/queue-hold" {
                self.progress.mark("queueHeld")
                if self.release.wait(timeout: .now() + 15) == .timedOut { self.progress.mark("queueHangGuard") }
                self.progress.mark("queueReleased")
            }
            completionHandler(nil)
        }
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func mark(_ flag: String) { self.lock.withLock { self.counts[flag, default: 0] += 1 } }
        func count(_ flag: String) -> Int { self.lock.withLock { self.counts[flag, default: 0] } }
        func contains(_ flag: String) -> Bool { self.count(flag) > 0 }

        func waitFor(_ flag: String) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !self.contains(flag), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return self.contains(flag)
        }
    }
}
#endif
