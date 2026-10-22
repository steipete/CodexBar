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
        let settings = testSettingsStore(suiteName: "FleetAccountMenuProjectionTests-distinct-remote")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let localIdentity = "local-account"
        let localKey = AccountSnapshotSyncPayload.accountKey(for: localIdentity)
        let distinctKey = AccountSnapshotSyncPayload.accountKey(for: "remote-account")
        store.snapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "local@example.com",
                accountOrganization: nil,
                loginMethod: nil,
                accountID: localIdentity))
        let localCopy = Self.snapshot(accountKey: localKey, fetchedAt: Date(timeIntervalSince1970: 200))
        let distinct = Self.snapshot(accountKey: distinctKey, fetchedAt: Date(timeIntervalSince1970: 300))
        let localAccountKeys = store.cloudSyncLocalAccountKeys(for: .codex)

        let projection = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [distinct, localCopy],
            currentDeviceID: settings.iCloudSyncDeviceID,
            localAccountKeys: localAccountKeys,
            hasLocalUsage: true)

        #expect(store.cloudSyncAccountSnapshots().map(\.accountKey) == [localKey])
        #expect(localAccountKeys == [localKey])
        #expect(projection.fallback == nil)
        #expect(projection.additionalAccounts.map(\.accountKey) == [distinctKey])
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

@MainActor
struct FleetMenuBarSourceTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test
    func `menu bar shares the menus fleet selection and local account authority`() {
        let remote = self.remote()
        let projection = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [remote],
            currentDeviceID: "local-device",
            localAccountKeys: [],
            hasLocalUsage: false)
        let source = MenuBarUsageSource.resolve(localSnapshot: nil, fleetFallback: projection.fallback)
        #expect(source.isFleet)
        #expect(source.fleetSnapshot?.accountKey == remote.accountKey)
        #expect(source.snapshot?.primary?.usedPercent == 25)

        let local = UsageSnapshot(primary: nil, secondary: nil, updatedAt: self.now.addingTimeInterval(-60))
        let localSource = MenuBarUsageSource.resolve(localSnapshot: local, fleetFallback: projection.fallback)
        #expect(!localSource.isFleet)
        #expect(localSource.snapshot?.updatedAt == local.updatedAt)
        #expect(localSource.snapshot?.primary == nil)
        #expect(MenuBarUsageSource.resolve(localSnapshot: nil, fleetFallback: nil).snapshot == nil)
    }

    @Test
    func `other providers and this device cannot become the remote menu bar source`() {
        let otherProvider = FleetAccountMenuPlanner.projection(
            provider: .claude,
            snapshots: [self.remote()],
            currentDeviceID: "local-device",
            localAccountKeys: [],
            hasLocalUsage: false)
        let ownDevice = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [self.remote()],
            currentDeviceID: "remote-device",
            localAccountKeys: [],
            hasLocalUsage: false)
        let localAccount = FleetAccountMenuPlanner.projection(
            provider: .codex,
            snapshots: [self.remote()],
            currentDeviceID: "local-device",
            localAccountKeys: [],
            hasLocalUsage: true)
        for projection in [otherProvider, ownDevice, localAccount] {
            #expect(!MenuBarUsageSource.resolve(localSnapshot: nil, fleetFallback: projection.fallback).isFleet)
        }
    }

    @Test
    func `fleet usage does not enable credential gated local refresh`() throws {
        let settings = testSettingsStore(
            suiteName: "FleetMenuBarSourceTests-availability",
            userDefaults: InMemoryUserDefaults())
        let metadata = try #require(ProviderRegistry.shared.metadata[.openrouter])
        settings.setProviderEnabled(provider: .openrouter, metadata: metadata, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let projection = FleetAccountMenuPlanner.projection(
            provider: .openrouter,
            snapshots: [self.remote(provider: .openrouter)],
            currentDeviceID: "local-device",
            localAccountKeys: [],
            hasLocalUsage: false)
        let source = MenuBarUsageSource.resolve(localSnapshot: nil, fleetFallback: projection.fallback)
        #expect(source.isFleet)
        #expect(source.snapshot?.primary?.usedPercent == 25)
        #expect(!store.isEnabled(.openrouter))
        #expect(store.enabledFirstPartyProvidersForDisplay().contains(.openrouter))
        #expect(!store.enabledFirstPartyProvidersForBackgroundWork().contains(.openrouter))
    }

    @Test
    func `remote layout renders quota without identity local credits cost or pace`() {
        let settings = testSettingsStore(suiteName: "FleetMenuBarSourceTests", userDefaults: InMemoryUserDefaults())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.credits = CreditsSnapshot(remaining: 1234, events: [], updatedAt: self.now)
        let data = store.menuBarLayoutRenderData(
            provider: .codex,
            snapshot: self.remote().usage,
            iconKey: "fixture",
            accountLabel: "Remote fixture account",
            costs: .init(today: "$9", last30Days: "$90", todayUSD: 9, last30DaysUSD: 90),
            includeLocalDerivedData: false,
            now: self.now)
        #expect(data.primary?.usedPercent == 25)
        #expect(data.accountLabel == nil)
        #expect(data.balance == nil)
        #expect(data.costToday == nil)
        #expect(data.cost30d == nil)
        #expect(data.sessionPace == nil)
        #expect(data.weeklyPace == nil)
        #expect(data.runsOut == nil)
        let output = MenuBarLayoutRenderer().render(
            layout: .init(lines: [[.percent(window: .session)]]),
            data: data,
            icon: nil,
            options: MenuBarLayoutRendererTests().options(showUsed: false))
        #expect(output.attributedTitle.string == "5h 75%")
        #expect(store.snapshots.isEmpty)
        #expect(store.cloudSyncAccountSnapshots().isEmpty)
    }

    @Test
    func `highest usage includes fleet providers without local credentials`() throws {
        let settings = testSettingsStore(
            suiteName: "FleetMenuBarSourceTests-highest",
            userDefaults: InMemoryUserDefaults())
        for provider in [UsageProvider.claude, .openrouter] {
            let metadata = try #require(ProviderRegistry.shared.metadata[provider])
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: true)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setSnapshotForTesting(self.remote(provider: .claude, usedPercent: 10).usage, provider: .claude)
        let remote = self.remote(provider: .openrouter, usedPercent: 90)
        let highest = store.providerWithHighestUsage(
            candidateProviders: [.claude, .openrouter],
            usageSource: { provider in
                provider == .openrouter ? .fleet(remote) : .local(store.menuBarSnapshot(for: provider.instanceID))
            },
            now: self.now)
        #expect(highest?.provider == .openrouter)
        #expect(highest?.usedPercent == 90)
        #expect(!store.isEnabled(.openrouter))
        #expect(store.snapshots[.openrouter] == nil)
    }

    private func remote(
        provider: ProviderInstanceID = .codex,
        usedPercent: Double = 25) -> AccountSnapshotSyncPayload
    {
        AccountSnapshotSyncPayload(
            provider: provider,
            deviceID: "remote-device",
            accountKey: "fixture",
            fetchedAt: self.now,
            displayLabel: "Remote fixture account",
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: self.now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: self.now))
    }
}
