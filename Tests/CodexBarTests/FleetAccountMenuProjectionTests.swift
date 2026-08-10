import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct FleetAccountMenuProjectionTests {
    @Test
    func `remote account appears only without a local equivalent`() {
        let remote = Self.snapshot(accountKey: "remote", fetchedAt: Date(timeIntervalSince1970: 200))

        let visible = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [remote],
            currentDeviceID: "local-device",
            localAccountKeys: [],
            hasLocalUsage: true)
        let hidden = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [remote],
            currentDeviceID: "local-device",
            localAccountKeys: ["remote"],
            hasLocalUsage: true)

        #expect(visible.additionalAccounts.map(\.accountKey) == ["remote"])
        #expect(hidden.additionalAccounts.isEmpty)
    }

    @Test
    func `local usage wins over an equivalent remote snapshot`() {
        let remote = Self.snapshot(accountKey: "shared", fetchedAt: Date(timeIntervalSince1970: 200))
        let projection = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [remote],
            currentDeviceID: "local-device",
            localAccountKeys: ["shared"],
            hasLocalUsage: true)

        #expect(projection.fallback == nil)
        #expect(projection.additionalAccounts.isEmpty)
    }

    @Test
    func `genuinely distinct remote account remains beside local usage`() {
        let localCopy = Self.snapshot(accountKey: "local", fetchedAt: Date(timeIntervalSince1970: 200))
        let distinct = Self.snapshot(accountKey: "remote", fetchedAt: Date(timeIntervalSince1970: 300))
        let projection = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [distinct, localCopy],
            currentDeviceID: "local-device",
            localAccountKeys: ["local"],
            hasLocalUsage: true)

        #expect(projection.fallback == nil)
        #expect(projection.additionalAccounts.map(\.accountKey) == ["remote"])
    }

    @Test
    func `fallback selects the freshest remote snapshot`() {
        let old = Self.snapshot(
            accountKey: "old",
            fetchedAt: Date(timeIntervalSince1970: 100),
            deviceID: "remote-one")
        let fresh = Self.snapshot(accountKey: "fresh", fetchedAt: Date(timeIntervalSince1970: 300))
        let sameAccountNewer = Self.snapshot(
            accountKey: "old",
            fetchedAt: Date(timeIntervalSince1970: 250),
            deviceID: "remote-two")
        let projection = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [old, fresh, sameAccountNewer],
            currentDeviceID: "local-device",
            localAccountKeys: [],
            hasLocalUsage: false)

        #expect(projection.fallback?.accountKey == "fresh")
        #expect(projection.additionalAccounts.map(\.accountKey) == ["old"])
        #expect(projection.additionalAccounts.first?.fetchedAt == sameAccountNewer.fetchedAt)
        #expect(projection.additionalAccounts.first?.deviceID == "remote-two")
    }

    @Test
    func `equal freshness remote copies choose a deterministic device`() {
        let fetchedAt = Date(timeIntervalSince1970: 200)
        let first = Self.snapshot(accountKey: "shared", fetchedAt: fetchedAt, deviceID: "remote-a")
        let second = Self.snapshot(accountKey: "shared", fetchedAt: fetchedAt, deviceID: "remote-b")

        let forward = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [first, second],
            currentDeviceID: "local-device",
            localAccountKeys: [],
            hasLocalUsage: false)
        let reversed = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [second, first],
            currentDeviceID: "local-device",
            localAccountKeys: [],
            hasLocalUsage: false)

        #expect(forward.fallback?.deviceID == "remote-b")
        #expect(reversed.fallback?.deviceID == forward.fallback?.deviceID)
        #expect(forward.additionalAccounts.isEmpty)
        #expect(reversed.additionalAccounts.isEmpty)
    }

    @Test
    func `identity less local snapshot owns the legacy default account`() {
        let settings = testSettingsStore(suiteName: "FleetAccountMenuProjectionTests-legacy-default")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.snapshots[.openrouter] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 100))
        let remote = Self.snapshot(
            provider: .openrouter,
            accountKey: AccountSnapshotSyncPayload.accountKey(for: nil),
            fetchedAt: Date(timeIntervalSince1970: 200))

        let projection = FleetAccountMenuPlanner.projection(
            provider: .openrouter,
            snapshots: [remote],
            currentDeviceID: settings.iCloudSyncDeviceID,
            localAccountKeys: store.cloudSyncLocalAccountKeys(for: .openrouter),
            hasLocalUsage: true)

        #expect(store.cloudSyncLocalAccountKeys(for: .openrouter) == ["default"])
        #expect(projection.fallback == nil)
        #expect(projection.additionalAccounts.isEmpty)
    }

    @Test
    func `identity less local snapshot also owns the provider email alias`() {
        let settings = testSettingsStore(suiteName: "FleetAccountMenuProjectionTests-default-email-alias")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.snapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 100))
        let email = "person@example.com"
        let emailKey = AccountSnapshotSyncPayload.accountKey(for: email)
        store.accountInfoCache[.codex] = UsageStore.AccountInfoCacheEntry(
            account: AccountInfo(email: email, plan: nil),
            configRevision: settings.configRevision,
            expiresAt: .distantFuture)
        let remote = Self.snapshot(accountKey: emailKey, fetchedAt: Date(timeIntervalSince1970: 200))
        let localAccountKeys = store.cloudSyncLocalAccountKeys(for: .codex)

        let projection = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [remote],
            currentDeviceID: settings.iCloudSyncDeviceID,
            localAccountKeys: localAccountKeys,
            hasLocalUsage: true)

        #expect(localAccountKeys == [AccountSnapshotSyncPayload.accountKey(for: nil), emailKey])
        #expect(projection.fallback == nil)
        #expect(projection.additionalAccounts.isEmpty)
    }

    @Test
    func `fleet badge uses compact staleness`() {
        let now = Date(timeIntervalSince1970: 10000)

        #expect(FleetAccountMenuPlanner.staleness(fetchedAt: now.addingTimeInterval(-60), now: now) == "1m ago")
        #expect(FleetAccountMenuPlanner.staleness(fetchedAt: now.addingTimeInterval(-3600), now: now) == "1h ago")
        #expect(FleetAccountMenuPlanner.badge(
            deviceName: "Studio",
            fetchedAt: now.addingTimeInterval(-3600),
            now: now) == "via Studio · 1h ago")
    }

    private static func snapshot(
        provider: ProviderInstanceID = .codex,
        accountKey: String,
        fetchedAt: Date,
        deviceID: String = "remote-device") -> AccountSnapshotSyncPayload
    {
        AccountSnapshotSyncPayload(
            provider: provider,
            deviceID: deviceID,
            accountKey: accountKey,
            fetchedAt: fetchedAt,
            displayLabel: "person@example.com",
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 25,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: fetchedAt))
    }
}
