import Foundation
import Testing
@testable import CodexBarCLI

struct CLIServeCacheLifecycleTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1000)

        func now() -> Date {
            self.lock.withLock { self.date }
        }

        func advance(by interval: TimeInterval) {
            self.lock.withLock { self.date = self.date.addingTimeInterval(interval) }
        }
    }

    @Test
    func `forced refreshes discard expired configuration variants`() async {
        let clock = Clock()
        let cache = CLIServeResponseCache(wallClock: clock.now)
        let response = CLILocalHTTPResponse(
            status: .ok,
            body: Data(#"[{"provider":"codex","value":1}]"#.utf8),
            usageCacheKeys: ["synthetic-account"])

        for generation in 0..<3 {
            for kind in ["usage", "cost", "dashboard"] {
                let result = await CodexBarCLI.cachedServeResponse(
                    key: "\(kind):default",
                    cache: cache,
                    refreshInterval: 60,
                    requestTimeout: 0,
                    configFingerprint: "config-\(generation)",
                    forceRefresh: true)
                {
                    response
                }
                #expect(result.body == response.body)
            }
            #expect(await cache.cachedEntryCount() == 3)
            #expect(await cache.cachedStaleVariantCount() == 3)
            clock.advance(by: CLIServeResponseCache.maximumStaleTTL + 1)
        }
        await cache.operations.shutdown()
    }
}
