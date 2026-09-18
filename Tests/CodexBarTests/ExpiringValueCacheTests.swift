import Foundation
import Testing
@testable import CodexBarCore

struct ExpiringValueCacheTests {
    @Test
    func `cache preserves empty results until expiry and invalidates independently`() {
        let first = ExpiringValueCache<[String]>(ttl: 5)
        let second = ExpiringValueCache<[String]>(ttl: 5)
        let now = Date(timeIntervalSince1970: 100)
        first.store([], now: now)
        second.store(["second"], now: now)
        #expect(first.load(now: now.addingTimeInterval(4)) == [])
        #expect(first.load(now: now.addingTimeInterval(5)) == nil)
        // Expiration removes the entry; a clock change cannot resurrect it.
        #expect(first.load(now: now) == nil)
        first.store(["new"], now: now)
        first.invalidate()
        #expect(first.load(now: now) == nil)
        #expect(second.load(now: now) == ["second"])
    }
}
