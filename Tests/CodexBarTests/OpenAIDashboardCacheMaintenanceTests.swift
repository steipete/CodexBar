import Foundation
import Testing
import WebKit
@testable import CodexBarCore

@MainActor
struct OpenAIDashboardCacheMaintenanceTests {
    @Test
    func `launch maintenance is inert in test processes`() async {
        #expect(TestProcessSafety.isRunning)
        await OpenAIDashboardWebsiteDataStore.clearNetworkCaches()
    }

    @Test
    func `daily maintenance bounds cache growth and retains session data`() async {
        let maintenance = OpenAIDashboardCacheMaintenance()
        let store = FakeStore()
        let start = Date(timeIntervalSince1970: 0)
        for day in 0..<4 {
            store.data[WKWebsiteDataTypeDiskCache, default: 0] += 1024
            await maintenance.clearIfNeeded(store, now: start.addingTimeInterval(Double(day) * 86400))
            #expect(store.data[WKWebsiteDataTypeDiskCache] == nil)
            store.data[WKWebsiteDataTypeDiskCache] = 64
            await maintenance.clearIfNeeded(store, now: start.addingTimeInterval(Double(day) * 86400 + 1))
            #expect(store.data[WKWebsiteDataTypeDiskCache] == 64)
        }
        #expect(store.removals == 4)
        #expect(store.data[WKWebsiteDataTypeCookies] == 1)
        #expect(store.data[WKWebsiteDataTypeLocalStorage] == 1)
        #expect(store.data[WKWebsiteDataTypeIndexedDBDatabases] == 1)
    }

    @Test
    func `default and account stores are maintained independently and ephemeral stores are skipped`() async {
        let maintenance = OpenAIDashboardCacheMaintenance()
        let stores = [FakeStore(identifier: nil), FakeStore(), FakeStore(isPersistent: false)]
        for store in stores {
            await maintenance.clearIfNeeded(store)
        }
        #expect(stores.map(\.removals) == [1, 1, 0])
        let reopened = FakeStore(identifier: stores[1].identifier)
        await maintenance.clearIfNeeded(reopened)
        #expect(reopened.removals == 0)
    }

    @Test
    func `retirement removes only the exact removed managed scope`() async throws {
        let account = Self.account
        let managedID = try #require(OpenAIDashboardWebsiteDataStore.identifier(
            forAccountEmail: account.email, scope: .managedAccount(account.id)))
        let liveID = try #require(OpenAIDashboardWebsiteDataStore.identifier(forAccountEmail: account.email))
        let unknownID = UUID()
        var released: [UUID] = []
        var removed: [UUID] = []
        await OpenAIDashboardWebsiteDataStore.removeStore(
            forRemovedAccount: account,
            identifiers: [managedID, liveID, unknownID],
            isStillRemoved: { true },
            releaseCachedStore: { released.append($0) },
            remove: {
                #expect(released == [$0])
                removed.append($0)
            })
        #expect(removed == [managedID])
    }

    @Test
    func `unknown or reappearing account mappings never remove a store`() async throws {
        let account = Self.account
        let managedID = try #require(OpenAIDashboardWebsiteDataStore.identifier(
            forAccountEmail: account.email, scope: .managedAccount(account.id)))
        var removed: [UUID] = []
        await OpenAIDashboardWebsiteDataStore.removeStore(
            forRemovedAccount: account,
            identifiers: [UUID()],
            isStillRemoved: { true },
            releaseCachedStore: { _ in Issue.record("Unknown stores must keep their owners") },
            remove: { removed.append($0) })
        await OpenAIDashboardWebsiteDataStore.removeStore(
            forRemovedAccount: account,
            identifiers: [managedID],
            isStillRemoved: { false },
            releaseCachedStore: { _ in Issue.record("Live stores must keep their owners") },
            remove: { removed.append($0) })
        #expect(removed.isEmpty)
    }

    private static var account: ManagedCodexAccount {
        ManagedCodexAccount(
            id: UUID(),
            email: " CACHE@example.invalid ",
            managedHomePath: "/synthetic/managed",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
    }

    private final class FakeStore: OpenAIDashboardWebsiteCacheStore {
        let identifier: UUID?
        let isPersistent: Bool
        var removals = 0
        var data = [
            WKWebsiteDataTypeDiskCache: 1024,
            WKWebsiteDataTypeMemoryCache: 128,
            WKWebsiteDataTypeCookies: 1,
            WKWebsiteDataTypeLocalStorage: 1,
            WKWebsiteDataTypeIndexedDBDatabases: 1,
        ]

        init(identifier: UUID? = UUID(), isPersistent: Bool = true) {
            self.identifier = identifier
            self.isPersistent = isPersistent
        }

        func removeData(ofTypes types: Set<String>, modifiedSince date: Date) async {
            #expect(types == [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])
            #expect(date == .distantPast)
            self.removals += 1
            for type in types {
                self.data.removeValue(forKey: type)
            }
        }
    }
}
