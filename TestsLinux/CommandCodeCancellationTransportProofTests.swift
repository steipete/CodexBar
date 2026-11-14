#if os(Linux)
import Foundation
import FoundationNetworking
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized)
struct CommandCodeCancellationTransportProofTests {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        let progress = CancellationTestProgress()

        func record(_ entry: String) {
            self.lock.withLock {
                self.entries.append(entry)
                FileHandle.standardOutput.write(Data("COMMANDCODE_TRACE \(entry)\n".utf8))
            }
        }

        var events: [String] {
            self.lock.withLock { self.entries }
        }
    }

    /// Only redirects to the owned server and injects cancellation after a real HTTP response.
    /// Authentication errors are produced by CommandCodeUsageFetcher, never by this adapter.
    private struct Transport: ProviderHTTPTransport {
        let base: URL
        let client: ProviderHTTPClient
        let trace: Trace
        let cancelOn401: Bool

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            #expect(url.host == "api.commandcode.ai")
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            let candidate = cookie == "session=fixture-1" ? 1 : 2
            var local = request
            local.url = self.base.appendingPathComponent("candidate-\(candidate)\(url.path)")
            self.trace.record("transport candidate-\(candidate) \(url.path)")
            let response = try await self.client.data(for: local)
            let http = try #require(response.1 as? HTTPURLResponse)
            self.trace.record("response candidate-\(candidate) \(url.path) HTTP \(http.statusCode)")
            if url.path.hasSuffix("/subscriptions") {
                self.trace.progress.mark("subscriptionFinished-candidate-\(candidate)")
            }
            if self.cancelOn401, url.path.hasSuffix("/credits"), http.statusCode == 401 {
                self.trace.record("cancel after on-wire HTTP 401")
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return response
        }
    }

    @Test(arguments: [false, true])
    func `provider authentication failure stops browser traversal when cancelled`(cancelOn401: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("commandcode-transport-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for candidate in [1, 2] {
            try Data("session=fixture-\(candidate)".utf8)
                .write(to: root.appendingPathComponent("profile-\(candidate)"))
        }
        let trace = Trace()
        try await self.withServer(trace: trace) { base in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let transport = Transport(
                base: base, client: ProviderHTTPClient(session: session), trace: trace, cancelOn401: cancelOn401)
            let outcome = await Task {
                await self.fetch(root: root, transport: transport, trace: trace)
            }.value
            let events = trace.events
            print("COMMANDCODE_TRANSPORT_PROOF cancelOn401=\(cancelOn401) outcome=\(outcome)")
            for event in events {
                print("  \(event)")
            }
            #expect(events.contains("wire /candidate-1/internal/billing/credits -> HTTP 401"))
            #expect(events.contains("provider classified invalidCredentials"))
            #expect(outcome == (cancelOn401 ? "cancelled" : "invalidCredentials"))
            let reads = events.filter { $0.hasPrefix("read profile-") }
            #expect(reads == (cancelOn401 ? ["read profile-1"] : ["read profile-1", "read profile-2"]))
            if cancelOn401 {
                #expect(!events.contains { $0.contains("candidate-2") })
            }
        }
    }

    private func fetch(root: URL, transport: Transport, trace: Trace) async -> String {
        do {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(root.appendingPathComponent("cache")) {
                    let strategy = CommandCodeWebFetchStrategy(
                        usageLoader: { cookie in
                            do {
                                return try await CommandCodeUsageFetcher.fetchUsage(
                                    cookieHeader: cookie,
                                    session: transport)
                            } catch let error as CommandCodeUsageError {
                                if case .invalidCredentials = error {
                                    trace.record("provider classified invalidCredentials")
                                }
                                throw error
                            }
                        },
                        sessionLoader: { Self.candidates(root: root, trace: trace) })
                    _ = try await strategy.fetch(Self.context())
                }
            }
            return "unexpected success"
        } catch is CancellationError {
            return "cancelled"
        } catch CommandCodeUsageError.invalidCredentials {
            return "invalidCredentials"
        } catch {
            return "unexpected \(error)"
        }
    }

    private static func candidates(root: URL, trace: Trace) -> AnySequence<CommandCodeResolvedSession> {
        AnySequence([1, 2].lazy.map { candidate in
            let url = root.appendingPathComponent("profile-\(candidate)")
            guard let cookie = try? String(contentsOf: url, encoding: .utf8) else {
                fatalError("Owned profile fixture missing")
            }
            trace.record("read profile-\(candidate)")
            return CommandCodeResolvedSession(cookieHeader: cookie, sourceLabel: "Fixture \(candidate)")
        })
    }

    private static func context() -> ProviderFetchContext {
        let detection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 5,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: ProviderSettingsSnapshot.make(),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: detection),
            browserDetection: detection)
    }

    private func withServer(trace: Trace, operation: (URL) async throws -> Void) async throws {
        let (ready, started) = AsyncStream<Void>.makeStream()
        let server = CLILocalHTTPServer(host: "127.0.0.1", port: 0) { request in
            if request.path.hasSuffix("/credits") {
                let candidate = request.path.split(separator: "/").first ?? ""
                #expect(await trace.progress.waitFor("subscriptionFinished-\(candidate)"))
            }
            trace.record("wire \(request.path) -> HTTP 401")
            return CLILocalHTTPResponse(status: .unauthorized, body: Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let running = Task(executorPreference: CancellationFixtureExecutor.shared) {
            try await server.run { started.yield(); started.finish() }
        }
        defer { server.stop(); started.finish() }
        for await _ in ready {
            break
        }
        do {
            let port = try #require(server.listeningPort)
            let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
            try await operation(base)
        } catch {
            server.stop()
            _ = await running.result
            throw error
        }
        server.stop()
        try await running.value
    }
}
#endif
