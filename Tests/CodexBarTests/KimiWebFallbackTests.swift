import Foundation
import Testing
@testable import CodexBarCore

struct KimiWebFallbackTests {
    @Test(arguments: ["manual", "environment"])
    func `explicit tokens remain authoritative when rejected`(source: String) async {
        let calls = KimiFallbackCalls()
        let strategy = Self.strategy(calls: calls) { _ in throw KimiAPIError.invalidToken }
        let context = Self.context(
            source: source == "manual" ? .manual : .auto,
            manual: source == "manual" ? "kimi-auth=explicit" : nil,
            environment: source == "environment" ? ["KIMI_AUTH_TOKEN": "kimi-auth=explicit"] : [:])
        do {
            _ = try await strategy.fetch(context)
            Issue.record("Expected authoritative token rejection")
        } catch KimiAPIError.invalidToken {} catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(calls.snapshot == ["fetch:explicit"])
    }

    @Test
    func `cookie off never resolves automatic credentials`() async {
        let calls = KimiFallbackCalls()
        let strategy = Self.strategy(calls: calls) { _ in Self.usage() }
        do {
            _ = try await strategy.fetch(Self.context(source: .off))
            Issue.record("Expected missing token")
        } catch KimiAPIError.missingToken {} catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(calls.snapshot.isEmpty)
    }

    @Test
    func `production web strategy skips repeated tokens and retries rejected browser profiles`() async throws {
        let calls = KimiFallbackCalls()
        let strategy = Self.strategy(calls: calls) { token in
            guard token == "browser-current" else { throw KimiAPIError.invalidToken }
            return Self.usage()
        }
        let result = try await strategy.fetch(Self.context())
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(calls.snapshot == [
            "desktop", "fetch:desktop", "browser", "fetch:browser-old", "fetch:browser-current",
        ])
    }

    @Test
    func `successful desktop usage does not inspect browsers`() async throws {
        let calls = KimiFallbackCalls()
        _ = try await Self.strategy(calls: calls) { _ in Self.usage() }.fetch(Self.context())
        #expect(calls.snapshot == ["desktop", "fetch:desktop"])
    }

    @Test
    func `network errors do not advance to another account`() async {
        let calls = KimiFallbackCalls()
        do {
            _ = try await Self.strategy(calls: calls) { _ in throw URLError(.notConnectedToInternet) }
                .fetch(Self.context())
            Issue.record("Expected network failure")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
        #expect(calls.snapshot == ["desktop", "fetch:desktop"])
    }

    @Test(arguments: ["desktop", "browser-old"])
    func `cancellation racing token rejection stops further credential reads and requests`(cancelAt: String) async {
        let calls = KimiFallbackCalls()
        let task = Task {
            try await Self.strategy(calls: calls) { token in
                if token == cancelAt {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                throw KimiAPIError.invalidToken
            }.fetch(Self.context())
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        let expected = cancelAt == "desktop"
            ? ["desktop", "fetch:desktop"]
            : ["desktop", "fetch:desktop", "browser", "fetch:browser-old"]
        #expect(calls.snapshot == expected)
    }

    private static func strategy(
        calls: KimiFallbackCalls,
        fetch: @escaping @Sendable (String) async throws -> KimiUsageSnapshot) -> KimiWebFetchStrategy
    {
        KimiWebFetchStrategy(
            fetchUsage: { token in calls.add("fetch:\(token)"); return try await fetch(token) },
            desktopToken: { calls.add("desktop"); return "desktop" },
            browserTokens: { calls.add("browser"); return ["desktop", "browser-old", "browser-current"] })
    }

    private static func usage() -> KimiUsageSnapshot {
        KimiUsageSnapshot(
            weekly: .init(limit: "100", used: "25", remaining: "75", resetTime: nil),
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: 100))
    }

    private static func context(
        source: ProviderCookieSource = .auto,
        manual: String? = nil,
        environment: [String: String] = [:]) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: .make(kimi: .init(cookieSource: source, manualCookieHeader: manual)),
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: KimiFallbackClaudeStub(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}

private final class KimiFallbackCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func add(_ call: String) {
        self.lock.withLock { self.calls.append(call) }
    }

    var snapshot: [String] {
        self.lock.withLock { self.calls }
    }
}

private struct KimiFallbackClaudeStub: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ClaudeUsageError.parseFailed("fixture")
    }

    func debugRawProbe(model _: String) async -> String {
        "fixture"
    }

    func detectVersion() -> String? {
        nil
    }
}
