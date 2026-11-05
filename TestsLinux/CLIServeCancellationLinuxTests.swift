#if canImport(Glibc) || canImport(Musl)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Exercises the real authenticated route joining an owned, fixture-driven refresh.
/// Returning to inline cancellation in BoundedTaskJoin must prevent this refresh
/// from releasing the coordinator and make the on-wire timeout assertion fail.
extension BoundedTaskJoinTests {
    @Suite(.serialized)
    struct CLIServeCancellationLinuxTests {
        @Test(.timeLimit(.minutes(1)))
        func `snapshot refresh releases its slot while source cancellation is held`() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("serve-cancellation-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
            let config = CodexBarConfig(providers: UsageProvider.allCases.map {
                ProviderConfig(id: $0.instanceID, enabled: false)
            })
            try store.save(config)
            let fingerprint = try CodexBarCLI.serveConfigCacheToken(for: config)
            let key = try CodexBarCLI.serveDashboardOperationKey(
                identityMode: .redacted,
                usageBarsShowUsed: CodexBarCLI.usageBarsShowUsedFromDefaults(),
                provider: nil)
            let cache = CLIServeResponseCache()
            let runtime = ServeRuntime(
                configStore: store,
                cache: cache,
                providerOperations: CLIServeOperationCoordinator(),
                costOperations: CLIServeOperationCoordinator(),
                refreshInterval: 60,
                requestTimeout: 30,
                healthVersion: "0.0.0-fixture",
                dashboardAuth: CLIServeDashboardAuth(bearer: "fixture-token"),
                dashboardIdentityMode: .redacted,
                bindHost: "127.0.0.1")
            let progress = CancellationTestProgress()
            let release = DispatchSemaphore(value: 0)
            let (pending, finished) = AsyncStream<Void>.makeStream()
            let operation = Task { for await _ in pending {} }
            let (deadlines, deadline) = AsyncStream<Void>.makeStream()
            defer {
                release.signal()
                finished.finish()
                deadline.finish()
            }
            let source = Task<CLILocalHTTPResponse, Error> {
                try await withTaskCancellationHandler {
                    progress.mark("sourceStarted")
                    await operation.value
                    try Task.checkCancellation()
                    return CLILocalHTTPResponse(status: .ok, body: Data("unexpected".utf8))
                } onCancel: {
                    progress.mark("cancelling")
                    if release.wait(timeout: .now() + 30) == .timedOut { progress.mark("guardExpired") }
                    progress.mark("cancellationReturned")
                }
            }
            let refresh = Task {
                await CodexBarCLI.cachedServeResponse(
                    key: key,
                    cache: cache,
                    refreshInterval: 60,
                    requestTimeout: 30,
                    configFingerprint: fingerprint)
                {
                    let waitForDeadline: @Sendable (Duration) async throws -> Void = { _ in
                        progress.mark("joinWaiting")
                        for await _ in deadlines {
                            break
                        }
                        try Task.checkCancellation()
                    }
                    return await BoundedTaskJoinTiming.$sleep.withValue(waitForDeadline) {
                        switch await BoundedTaskJoin(sourceTask: source).value(joinGrace: .seconds(1)) {
                        case .timedOut: CodexBarCLI.serveTimeoutResponse()
                        case let .value(response): response
                        case .failure: CodexBarCLI.serveTimeoutResponse()
                        }
                    }
                }
            }
            let server = CLILocalHTTPServer(host: "127.0.0.1", port: 0, maximumConnections: 2) { request in
                await CodexBarCLI.handleServeRequest(request, runtime: runtime)
            }
            let serverTask = Task(executorPreference: CancellationFixtureExecutor.shared) {
                try await server.run { progress.mark("listening") }
            }
            defer { server.stop() }
            var snapshot: Task<String, Error>?
            let outcome: Result<Void, any Error>
            do {
                try #require(await progress.waitFor("listening"))
                try #require(await progress.waitFor("sourceStarted"))
                try #require(await progress.waitFor("joinWaiting"))
                let port = try #require(server.listeningPort)
                let health = try await Self.exchange(port: port, target: "/health")
                #expect(health.hasPrefix("HTTP/1.1 200 OK\r\n"))
                snapshot = Task {
                    defer { progress.mark("snapshotFinished") }
                    return try await Self.exchange(port: port, target: "/dashboard/v1/snapshot", authenticated: true)
                }
                // Prove the real route joined the synthetic refresh before firing its deadline.
                try #require(await Self.eventually { await cache.operations.snapshot().waiterCount == 2 })
                deadline.yield(())
                try #require(await progress.waitFor("cancelling"))
                let stillHealthy = try await Self.exchange(port: port, target: "/health")
                #expect(stillHealthy.hasPrefix("HTTP/1.1 200 OK\r\n"))
                let unauthorized = try await Self.exchange(port: port, target: "/dashboard/v1/snapshot")
                #expect(unauthorized.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
                let completed = await progress.waitFor("snapshotFinished")
                #expect(completed, "Authenticated snapshot stayed blocked behind source cancellation")
                if completed, let snapshot {
                    let timedOut = try await snapshot.value
                    #expect(timedOut.hasPrefix("HTTP/1.1 504 Gateway Timeout\r\n"))
                    #expect(timedOut.contains("Cache-Control: no-store\r\n"))
                    #expect(timedOut.hasSuffix(#"{"error":"request timed out"}"#))
                    try #require(await Self.eventually { await cache.operations.snapshot().operationCount == 0 })
                    // No accounts are enabled: these requests exercise the live producer without probes.
                    for _ in 0..<3 {
                        let recovered = try await Self.exchange(
                            port: port, target: "/dashboard/v1/snapshot", authenticated: true)
                        #expect(recovered.hasPrefix("HTTP/1.1 200 OK\r\n"))
                        #expect(recovered.contains("Cache-Control: no-store\r\n"))
                        let body = try #require(recovered.components(separatedBy: "\r\n\r\n").last)
                        let payload = try #require(JSONSerialization
                            .jsonObject(with: Data(body.utf8)) as? [String: Any])
                        #expect(payload["schemaVersion"] as? Int == 1)
                        #expect((payload["providers"] as? [Any])?.isEmpty == true)
                    }
                }
                #expect(!progress.contains("cancellationReturned"))
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            // Always release before cancelling, then drain every task, including failure paths.
            release.signal()
            finished.finish()
            deadline.finish()
            source.cancel()
            _ = await source.result
            _ = await refresh.value
            _ = await snapshot?.result
            #expect(await progress.waitFor("cancellationReturned"))
            #expect(!progress.contains("guardExpired"))
            #expect(await Self.eventually { await cache.operations.snapshot().operationCount == 0 })
            await cache.operations.shutdown()
            await runtime.providerOperations.shutdown()
            await runtime.costOperations.shutdown()
            server.stop()
            try await serverTask.value
            try outcome.get()
        }

        private static func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
            let limit = ContinuousClock.now.advanced(by: .seconds(10))
            repeat {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < limit
            return await condition()
        }

        /// Keep blocking fixture sockets off the cooperative executor; never use URLSession here.
        private static func exchange(port: UInt16, target: String, authenticated: Bool = false) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(with: Result {
                        #if canImport(Glibc)
                        let streamType = Int32(SOCK_STREAM.rawValue)
                        #else
                        let streamType = Int32(SOCK_STREAM)
                        #endif
                        let fd = socket(AF_INET, streamType, 0)
                        guard fd >= 0 else { throw POSIXError(.EIO) }
                        defer { close(fd) }
                        var timeout = timeval(tv_sec: 5, tv_usec: 0)
                        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
                            guard setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)) ==
                                0
                            else { throw POSIXError(.EIO) }
                        }
                        var address = sockaddr_in()
                        address.sin_family = sa_family_t(AF_INET)
                        address.sin_port = port.bigEndian
                        address.sin_addr.s_addr = inet_addr("127.0.0.1")
                        let connected = withUnsafePointer(to: &address) { pointer in
                            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
                        let authorization = authenticated ? "Authorization: Bearer fixture-token\r\n" : ""
                        let request = Array("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(authorization)\r\n".utf8)
                        try request.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < bytes.count {
                                let count = send(
                                    fd,
                                    bytes.baseAddress!.advanced(by: offset),
                                    bytes.count - offset,
                                    Int32(MSG_NOSIGNAL))
                                if count < 0, errno == EINTR { continue }
                                guard count > 0 else { throw POSIXError(.EIO) }
                                offset += count
                            }
                        }
                        var response = Data()
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        while true {
                            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                            if count < 0, errno == EINTR { continue }
                            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                            if count == 0 { break }
                            response.append(contentsOf: buffer.prefix(count))
                        }
                        guard let result = String(data: response, encoding: .utf8) else { throw POSIXError(.EILSEQ) }
                        return result
                    })
                }
            }
        }
    }
}
#endif
