import Foundation
import Testing
@testable import CodexBarCLI

struct CLIServeTimeoutTests {
    @Test
    func `clamped serve request timeout rejects oversized finite values`() {
        #expect(CodexBarCLI.clampedServeRequestTimeout(.greatestFiniteMagnitude) == 86400)
        #expect(CodexBarCLI.clampedServeRequestTimeout(1e308) == 86400)
        #expect(CodexBarCLI.clampedServeRequestTimeout(-5) == 0)
    }

    @Test
    func `queued in flight wait clamps oversized finite request timeout`() async {
        let cache = CLIServeResponseCache()
        let key = "usage:oversized-timeout"
        let gate = ServeFetchReleaseGate()

        async let blocker = CodexBarCLI.cachedServeResponse(
            key: key,
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 5)
        {
            await gate.waitForProceed()
            return Self.response("[{\"provider\":\"codex\"}]")
        }

        try? await Task.sleep(nanoseconds: 20_000_000)

        let lookup = await cache.responseOrStartFetch(
            for: key,
            requestTimeout: .greatestFiniteMagnitude,
            now: Date())

        await gate.proceed()
        _ = await blocker

        switch lookup {
        case .response:
            #expect(Bool(true))
        case .miss:
            Issue.record("expected coalesced response while key stayed in-flight")
        }
    }

    @Test
    func `same key waiter registered before fetch completes receives response`() async {
        let cache = CLIServeResponseCache()
        let key = "usage:sync-waiter"
        let gate = ServeFetchReleaseGate()

        async let first = CodexBarCLI.cachedServeResponse(
            key: key,
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 5)
        {
            await gate.waitForProceed()
            return Self.response("[{\"provider\":\"codex\",\"round\":1}]")
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(await cache.inFlightKeyCount() == 1)

        async let second = CodexBarCLI.cachedServeResponse(
            key: key,
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 1)
        {
            Self.response("[{\"provider\":\"codex\",\"round\":2}]")
        }

        await gate.proceed()
        let firstResponse = await first
        let secondResponse = await second

        #expect(firstResponse.status == .ok)
        #expect(secondResponse.status == .ok)
        #expect(Self.bodyString(secondResponse).contains("\"round\":1"))
    }

    @Test
    func `cleanup releases retained key when cooperative work exits early`() async throws {
        let cache = CLIServeResponseCache()
        let key = "usage:early-release"
        let start = Date()

        let first = await CodexBarCLI.cachedServeResponse(
            key: key,
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 0.08)
        {
            try? await Task.sleep(nanoseconds: 120_000_000)
            return Self.response("[{\"provider\":\"codex\",\"round\":1}]")
        }
        #expect(first.status == .gatewayTimeout)

        var clearedAt: TimeInterval?
        for _ in 0..<50 {
            if await cache.inFlightKeyCount() == 0 {
                clearedAt = Date().timeIntervalSince(start)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let cleared = try #require(clearedAt)
        #expect(cleared < 0.14)

        let second = await CodexBarCLI.cachedServeResponse(
            key: key,
            cache: cache,
            refreshInterval: 60,
            requestTimeout: 0.1)
        {
            Self.response("[{\"provider\":\"codex\",\"round\":2}]")
        }
        #expect(second.status == .ok)
    }

    private static func response(
        _ body: String,
        status: CLIHTTPStatus = .ok,
        usageCacheKeys: [String?]? = nil) -> CLILocalHTTPResponse
    {
        let data = Data(body.utf8)
        return CLILocalHTTPResponse(
            status: status,
            body: data,
            usageCacheKeys: usageCacheKeys ?? Self.syntheticUsageCacheKeys(data))
    }

    private static func bodyString(_ response: CLILocalHTTPResponse) -> String {
        String(data: response.body, encoding: .utf8) ?? ""
    }

    private static func syntheticUsageCacheKeys(_ data: Data) -> [String?]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.map { row in
            guard let provider = row["provider"] as? String else { return nil }
            let account = row["account"] as? String ?? "default"
            return "test:\(provider):\(account)"
        }
    }
}

private actor ServeFetchReleaseGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForProceed() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func proceed() {
        self.continuation?.resume()
        self.continuation = nil
    }
}
