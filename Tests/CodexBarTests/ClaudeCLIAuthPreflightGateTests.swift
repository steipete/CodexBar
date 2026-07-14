import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct ClaudeCLIAuthPreflightGateTests {
    @Test
    func `ambiguous timeout uses a short cooldown`() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ClaudeCLIAuthPreflightGate.BlockedUntilStore()

        await ClaudeCLIAuthPreflightGate.withBlockedUntilStoreOverrideForTesting(store) {
            ClaudeCLIAuthPreflightGate.recordTimeout(now: now)

            #expect(ClaudeCLIAuthPreflightGate.blockedUntil(now: now) == now.addingTimeInterval(15 * 60))
            #expect(ClaudeCLIAuthPreflightGate.blockedUntil(now: now.addingTimeInterval(15 * 60)) == nil)
        }
    }

    @Test
    func `generic failure uses a short cooldown`() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ClaudeCLIAuthPreflightGate.BlockedUntilStore()

        await ClaudeCLIAuthPreflightGate.withBlockedUntilStoreOverrideForTesting(store) {
            ClaudeCLIAuthPreflightGate.recordFailure(now: now)

            #expect(ClaudeCLIAuthPreflightGate.blockedUntil(now: now) == now.addingTimeInterval(15 * 60))
            #expect(ClaudeCLIAuthPreflightGate.blockedUntil(now: now.addingTimeInterval(15 * 60)) == nil)
        }
    }

    @Test
    func `user action bypasses and successful repair clears cooldown`() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ClaudeCLIAuthPreflightGate.BlockedUntilStore()

        await ClaudeCLIAuthPreflightGate.withBlockedUntilStoreOverrideForTesting(store) {
            ClaudeCLIAuthPreflightGate.recordTimeout(now: now)

            #expect(ClaudeCLIAuthPreflightGate.blockedUntil(interaction: .userInitiated, now: now) == nil)
            #expect(ClaudeCLIAuthPreflightGate.clear(now: now))
            #expect(ClaudeCLIAuthPreflightGate.blockedUntil(now: now) == nil)
        }
    }

    @Test
    func `persisted cooldown survives reload and expired state is removed`() {
        let key = ClaudeCLIAuthPreflightGate.blockedUntilKeyForTesting
        let defaults = UserDefaults.standard
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(15 * 60)
        defer { ClaudeCLIAuthPreflightGate.resetForTesting() }

        defaults.set(future.timeIntervalSince1970, forKey: key)
        ClaudeCLIAuthPreflightGate.reloadPersistedStateForTesting()

        #expect(ClaudeCLIAuthPreflightGate.blockedUntil(now: now) == future)
        #expect(ClaudeCLIAuthPreflightGate.blockedUntil(interaction: .userInitiated, now: now) == nil)

        defaults.set(now.addingTimeInterval(-1).timeIntervalSince1970, forKey: key)
        ClaudeCLIAuthPreflightGate.reloadPersistedStateForTesting()

        #expect(ClaudeCLIAuthPreflightGate.blockedUntil(now: now) == nil)
        #expect(defaults.object(forKey: key) == nil)
    }
}
#endif
