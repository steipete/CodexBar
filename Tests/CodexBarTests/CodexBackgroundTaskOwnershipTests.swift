import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension CodexBackgroundRefreshCoalescingTests {
    @Test
    func `cancelled credits cleanup preserves its same account replacement`() async throws {
        let settings = try self.makeSettingsStore(suite: "CodexBackgroundRefreshCoalescingTests-replacement")
        let account = try Self.installManagedAccount(email: "managed@example.com", settings: settings)
        defer { try? FileManager.default.removeItem(atPath: account.managedHomePath) }
        let store = self.makeStore(settings: settings)
        let blocker = BlockingCreditsLoader()
        store._test_codexCreditsLoaderOverride = { try await blocker.awaitResult() }

        store.scheduleCreditsRefreshIfNeeded()
        guard await blocker.waitUntilStartedWithin(count: 1) else {
            Issue.record("First credits refresh did not start")
            await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [])
            return
        }
        let first = store.creditsRefreshTask
        let accountKey = store.creditsRefreshTaskKey
        #expect(first != nil)
        #expect(accountKey != nil)
        store.cancelScheduledCreditsRefresh()
        store.scheduleCreditsRefreshIfNeeded()
        guard await blocker.waitUntilStartedWithin(count: 2) else {
            Issue.record("Replacement credits refresh did not start")
            await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [first].compactMap(\.self))
            return
        }
        let replacement = store.creditsRefreshTask
        #expect(replacement != nil)
        await blocker.resumeNext(with: .success(CreditsSnapshot(remaining: 10, events: [], updatedAt: Date())))
        await first?.value

        #expect(store.creditsRefreshTask == replacement)
        #expect(store.creditsRefreshTaskKey == accountKey)
        store.scheduleCreditsRefreshIfNeeded()
        #expect(store.creditsRefreshTask == replacement)
        #expect(await blocker.startedCount() == 2)

        await self.cancelCreditsWork(store: store, blocker: blocker, tasks: [replacement].compactMap(\.self))
        #expect(store.creditsRefreshTask == nil)
        #expect(store.creditsRefreshTaskKey == nil)
    }
}
