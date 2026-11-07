import Foundation
import Testing
import WebKit
@testable import CodexBarCore

@MainActor
struct OpenAIDashboardCacheMaintenanceTests {
    @Test
    func `launch maintenance is inert in test processes`() async {
        #expect(TestProcessSafety.isRunning)
        #expect(await OpenAIDashboardWebsiteDataStore.clearNetworkCaches() == 0)
    }

    @Test
    func `cold enumeration skips absent and empty directories and initializes before listing stores`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls: [String] = []
        let identifier = UUID()
        func identifiers() async -> [UUID] {
            await OpenAIDashboardWebsiteDataStore.existingIdentifiers(
                in: directory,
                initialize: { calls.append("initialize") },
                enumerate: {
                    calls.append("enumerate")
                    return [identifier]
                })
        }
        #expect(await identifiers().isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(await identifiers().isEmpty)
        #expect(calls.isEmpty)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(identifier.uuidString), withIntermediateDirectories: true)
        #expect(await identifiers() == [identifier])
        #expect(calls == ["initialize", "enumerate"])
    }

    @Test
    func `daily sweep is due only after a full day`() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(OpenAIDashboardWebsiteDataStore.sweepIsDue(lastSweep: nil, now: start))
        #expect(!OpenAIDashboardWebsiteDataStore.sweepIsDue(lastSweep: start, now: start))
        #expect(!OpenAIDashboardWebsiteDataStore.sweepIsDue(
            lastSweep: start, now: start.addingTimeInterval(86399)))
        #expect(OpenAIDashboardWebsiteDataStore.sweepIsDue(
            lastSweep: start, now: start.addingTimeInterval(86400)))
    }

    @Test
    func `cold child process sweeps a real isolated WebKit store`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = TestBuildProducts.executableURL(named: "CodexBar")
        let directory = home.appendingPathComponent(
            "Library/WebKit/CodexBar/WebsiteDataStore/11111111-1111-4111-8111-111111111111")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        // cfprefsd otherwise shares the real user's application domain despite CFFIXED_USER_HOME.
        process.arguments = ["-p", """
        (version 1)(allow default)
        (deny mach-lookup (global-name "com.apple.cfprefsd.agent"))
        (deny mach-lookup (global-name "com.apple.cfprefsd.daemon"))
        """, executable.path]
        // No test-runner flags: the child must use the production WebKit path.
        process.environment = [
            "HOME": home.path, "CFFIXED_USER_HOME": home.path, "TMPDIR": home.path,
            "PATH": "/usr/bin:/bin", "CODEXBAR_WEBKIT_SMOKE": "1", "CODEXBAR_DISABLE_KEYCHAIN_ACCESS": "1",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        #expect(text?.contains("CODEXBAR_WEBKIT_SMOKE_OK") == true)
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
