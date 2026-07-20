import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreDisabledProviderCleanupTests {
    @Test
    func `disabled cleanup rejects stale provider publication after re-enable`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-provider-race")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        try Self.setOnlyProvider(.amp, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        let stale = Self.usageSnapshot(usedPercent: 71)
        store._test_providerFetchOutcomeOverride = { _ in
            await gate.suspend()
            return Self.providerOutcome(snapshot: stale)
        }

        let staleTask = Task { await store.refreshProvider(.amp) }
        await gate.waitUntilStarted()
        try Self.setProvider(.amp, enabled: false, settings: settings)
        store.clearDisabledProviderState(enabledProviders: [])
        try Self.setProvider(.amp, enabled: true, settings: settings)
        await gate.resume()
        await staleTask.value

        #expect(store.snapshot(for: .amp) == nil)

        let fresh = Self.usageSnapshot(usedPercent: 19)
        store._test_providerFetchOutcomeOverride = { _ in Self.providerOutcome(snapshot: fresh) }
        await store.refreshProvider(.amp)
        #expect(store.snapshot(for: .amp)?.primary?.usedPercent == 19)
    }

    @Test
    func `quick provider toggle rejects stale publication before cleanup runs`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-provider-config-race")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        try Self.setOnlyProvider(.amp, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        store._test_providerFetchOutcomeOverride = { _ in
            await gate.suspend()
            return Self.providerOutcome(snapshot: Self.usageSnapshot(usedPercent: 71))
        }

        let staleTask = Task { await store.refreshProvider(.amp) }
        await gate.waitUntilStarted()
        try Self.setProvider(.amp, enabled: false, settings: settings)
        try Self.setProvider(.amp, enabled: true, settings: settings)
        await gate.resume()
        await staleTask.value

        #expect(store.snapshot(for: .amp) == nil)
    }

    @Test
    func `provider order change preserves in-flight publication`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-provider-order")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        try Self.setOnlyProvider(.amp, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        store._test_providerFetchOutcomeOverride = { _ in
            await gate.suspend()
            return Self.providerOutcome(snapshot: Self.usageSnapshot(usedPercent: 43))
        }

        let refreshTask = Task { await store.refreshProvider(.amp) }
        await gate.waitUntilStarted()
        settings.setProviderOrder(Array(settings.orderedProviders().reversed()))
        await gate.resume()
        await refreshTask.value

        #expect(store.snapshot(for: .amp)?.primary?.usedPercent == 43)
    }

    @Test
    func `provider config round trip rejects stale publication before cleanup runs`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-provider-config")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        try Self.setOnlyProvider(.amp, enabled: true, settings: settings)
        settings.updateProviderConfig(provider: .amp) { $0.source = .auto }
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        store._test_providerFetchOutcomeOverride = { _ in
            await gate.suspend()
            return Self.providerOutcome(snapshot: Self.usageSnapshot(usedPercent: 71))
        }

        let staleTask = Task { await store.refreshProvider(.amp) }
        await gate.waitUntilStarted()
        settings.updateProviderConfig(provider: .amp) { $0.source = .api }
        settings.updateProviderConfig(provider: .amp) { $0.source = .auto }
        await gate.resume()
        await staleTask.value

        #expect(store.snapshot(for: .amp) == nil)
    }

    @Test
    func `base URL change rejects suspended token account result and cache`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-token-base-url")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        try Self.setOnlyProvider(.sub2api, enabled: true, settings: settings)
        settings.updateProviderConfig(provider: .sub2api) { config in
            config.enterpriseHost = "https://first.example.test"
        }
        settings.addTokenAccount(provider: .sub2api, label: "Primary", token: "k1")
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        store._test_providerFetchOutcomeOverride = { _ in
            await gate.suspend()
            return Self.providerOutcome(snapshot: Self.usageSnapshot(usedPercent: 71))
        }

        let staleTask = Task { await store.refreshProvider(.sub2api) }
        await gate.waitUntilStarted()
        settings.updateProviderConfig(provider: .sub2api) { config in
            config.enterpriseHost = "https://second.example.test"
        }
        await gate.resume()
        await staleTask.value

        #expect(store.snapshot(for: .sub2api) == nil)
        #expect(store.accountSnapshots[.sub2api] == nil)
    }

    @Test
    func `disabled cleanup preserves explicit allow-disabled refresh`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-allow-disabled")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        try Self.setOnlyProvider(.amp, enabled: false, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        store._test_providerFetchOutcomeOverride = { _ in
            await gate.suspend()
            return Self.providerOutcome(snapshot: Self.usageSnapshot(usedPercent: 27))
        }

        let refreshTask = Task { await store.refreshProvider(.amp, allowDisabled: true) }
        await gate.waitUntilStarted()
        store.clearDisabledProviderState(enabledProviders: [])
        await gate.resume()
        await refreshTask.value

        #expect(store.snapshot(for: .amp)?.primary?.usedPercent == 27)

        store.clearDisabledProviderState(enabledProviders: [])
        #expect(store.snapshot(for: .amp) == nil)
    }

    @Test
    func `disabled cleanup rejects stale status success after re-enable`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-status-success")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true
        try Self.setOnlyProvider(.codex, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        store._test_providerStatusFetchOverride = { _ in
            await gate.suspend()
            return ProviderStatus(indicator: .major, description: "stale", updatedAt: Date())
        }

        let staleTask = Task { await store.refreshProviderStatus(.codex) }
        await gate.waitUntilStarted()
        try Self.setProvider(.codex, enabled: false, settings: settings)
        try Self.setProvider(.codex, enabled: true, settings: settings)
        await gate.resume()
        await staleTask.value

        #expect(store.statuses[.codex] == nil)

        store._test_providerStatusFetchOverride = { _ in
            ProviderStatus(indicator: .none, description: "fresh", updatedAt: Date())
        }
        await store.refreshProviderStatus(.codex)
        #expect(store.statuses[.codex]?.description == "fresh")
    }

    @Test
    func `disabled cleanup rejects stale status failure after re-enable`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-status-failure")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true
        try Self.setOnlyProvider(.codex, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        store._test_providerStatusFetchOverride = { _ in
            await gate.suspend()
            throw CleanupTestError.failed
        }

        let staleTask = Task { await store.refreshProviderStatus(.codex) }
        await gate.waitUntilStarted()
        try Self.setProvider(.codex, enabled: false, settings: settings)
        store.clearDisabledProviderState(enabledProviders: [])
        try Self.setProvider(.codex, enabled: true, settings: settings)
        await gate.resume()
        await staleTask.value

        #expect(store.statuses[.codex] == nil)
    }

    @Test
    func `disabled cleanup rejects stale token result after re-enable`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-token-race")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        try Self.setOnlyProvider(.codex, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        var loadCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, historyDays in
            loadCount += 1
            if loadCount == 1 {
                await gate.suspend()
                return Self.tokenSnapshot(tokens: 710, historyDays: historyDays)
            }
            return Self.tokenSnapshot(tokens: 190, historyDays: historyDays)
        }

        let staleTask = Task { await store.refreshTokenUsage(.codex, force: true) }
        await gate.waitUntilStarted()
        try Self.setProvider(.codex, enabled: false, settings: settings)
        store.clearDisabledProviderState(enabledProviders: [])
        try Self.setProvider(.codex, enabled: true, settings: settings)
        await gate.resume()
        await staleTask.value
        for _ in 0..<100 where store.tokenSnapshot(for: .codex) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 190)
        #expect(loadCount == 2)
    }

    @Test
    func `disabled cleanup replaces stale token failure with fresh retry`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-token-failure")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        try Self.setOnlyProvider(.codex, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        var loadCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, historyDays in
            loadCount += 1
            if loadCount == 1 {
                await gate.suspend()
                throw CleanupTestError.failed
            }
            return Self.tokenSnapshot(tokens: 190, historyDays: historyDays)
        }

        let staleTask = Task { await store.refreshTokenUsage(.codex, force: true) }
        await gate.waitUntilStarted()
        try Self.setProvider(.codex, enabled: false, settings: settings)
        store.clearDisabledProviderState(enabledProviders: [])
        try Self.setProvider(.codex, enabled: true, settings: settings)
        await gate.resume()
        await staleTask.value
        for _ in 0..<100 where store.tokenSnapshot(for: .codex) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 190)
        #expect(store.tokenError(for: .codex) == nil)
        #expect(loadCount == 2)
    }

    @Test
    func `disabled token completion preserves retry through active sequence`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-token-sequence")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        try Self.setOnlyProvider(.codex, enabled: true, settings: settings)
        try Self.setProvider(.claude, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let codexGate = CleanupAsyncGate()
        let claudeGate = CleanupAsyncGate()
        var codexLoads = 0
        var claudeLoads = 0
        store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, _, historyDays in
            switch provider {
            case .codex:
                codexLoads += 1
                if codexLoads == 1 {
                    await codexGate.suspend()
                    return Self.tokenSnapshot(tokens: 710, historyDays: historyDays)
                }
                return Self.tokenSnapshot(tokens: 190, historyDays: historyDays)
            case .claude:
                claudeLoads += 1
                if claudeLoads == 1 {
                    await claudeGate.suspend()
                }
                return Self.tokenSnapshot(tokens: 50, historyDays: historyDays)
            default:
                return Self.tokenSnapshot(tokens: 1, historyDays: historyDays)
            }
        }

        store.scheduleTokenRefreshForTesting()
        await codexGate.waitUntilStarted()
        try Self.setProvider(.codex, enabled: false, settings: settings)
        store.clearDisabledProviderState(enabledProviders: [.claude])
        await codexGate.resume()

        await claudeGate.waitUntilStarted()
        try Self.setProvider(.codex, enabled: true, settings: settings)
        store.scheduleTokenRefreshForTesting()
        await claudeGate.resume()

        for _ in 0..<200
            where store.tokenSnapshot(for: .codex)?.sessionTokens != 190 || claudeLoads != 2
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 190)
        #expect(codexLoads == 2)
        #expect(claudeLoads == 1)
    }

    @Test
    func `token configuration change rejects stale result`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-token-scope")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = 30
        try Self.setOnlyProvider(.codex, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        var loadCount = 0
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, historyDays in
            loadCount += 1
            if loadCount == 1 {
                await gate.suspend()
                return Self.tokenSnapshot(tokens: 710, historyDays: historyDays)
            }
            return Self.tokenSnapshot(tokens: 190, historyDays: historyDays)
        }

        let staleTask = Task { await store.refreshTokenUsage(.codex, force: true) }
        await gate.waitUntilStarted()
        settings.costUsageHistoryDays = 7
        await gate.resume()
        await staleTask.value
        for _ in 0..<100 where store.tokenSnapshot(for: .codex) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 190)
        #expect(loadCount == 2)
    }

    @Test
    func `cached token hydration rejects disable re-enable completion`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-token-cache")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        try Self.setOnlyProvider(.codex, enabled: true, settings: settings)
        let store = Self.makeUsageStore(settings: settings)
        let gate = CleanupAsyncGate()
        store._test_cachedCodexTokenSnapshotLoaderOverride = { now, _, historyDays in
            await gate.suspend()
            return (
                snapshot: Self.tokenSnapshot(tokens: 710, historyDays: historyDays, updatedAt: now),
                lastRefreshAt: now)
        }

        store.hydrateCachedTokenSnapshots()
        await gate.waitUntilStarted()
        try Self.setProvider(.codex, enabled: false, settings: settings)
        try Self.setProvider(.codex, enabled: true, settings: settings)
        await gate.resume()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenLastAttemptAt(for: .codex) == nil)
    }

    @Test
    func `disabled provider cleanup clears derived reset scope and warning state`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-derived")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        let staleSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: Date(), resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let retainedSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: Date(), resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(staleSnapshot, provider: .kilo)
        store.lastKnownResetSnapshots[.kilo] = staleSnapshot
        store.lastKnownResetSnapshots[.codex] = retainedSnapshot
        store.kiloScopeSnapshots = [
            KiloScopeSnapshot(
                id: KiloUsageScope.personal.scopeIdentifier,
                scope: .personal,
                snapshot: staleSnapshot,
                errorMessage: nil,
                sourceLabel: "personal"),
            KiloScopeSnapshot(
                id: "org-stale",
                scope: .organization(id: "org-stale", name: "Stale Org"),
                snapshot: staleSnapshot,
                errorMessage: nil,
                sourceLabel: "org"),
        ]
        store.providerStorageFootprints[.kilo] = ProviderStorageFootprint(
            provider: .kilo,
            totalBytes: 42,
            paths: ["/tmp/kilo"],
            missingPaths: [],
            unreadablePaths: [],
            components: [],
            updatedAt: Date())
        store.quotaWarningState[
            UsageStore.QuotaWarningStateKey(provider: .kilo, window: .session, accountDiscriminator: nil),
        ] =
            UsageStore.QuotaWarningState(lastRemaining: 20, firedThresholds: [50], source: .primary)
        store.quotaWarningState[
            UsageStore.QuotaWarningStateKey(provider: .codex, window: .session, accountDiscriminator: nil),
        ] =
            UsageStore.QuotaWarningState(lastRemaining: 80, firedThresholds: [20], source: .primary)
        store.predictivePaceWarningNotifiedKeys = [
            PredictivePaceWarningStateKey(
                provider: .kilo,
                accountDiscriminator: "kilo",
                window: .session,
                resetWindow: PredictivePaceWarningResetWindow(windowMinutes: 300, resetsAt: Date())),
            PredictivePaceWarningStateKey(
                provider: .codex,
                accountDiscriminator: "codex",
                window: .session,
                resetWindow: PredictivePaceWarningResetWindow(windowMinutes: 300, resetsAt: Date())),
        ]
        store.lastTokenFetchAt[.kilo] = Date()
        store.lastTokenFetchScope[.kilo] = "stale"

        store.clearDisabledProviderState(enabledProviders: Set(store.enabledProvidersForDisplay()))

        #expect(store.snapshot(for: .kilo) == nil)
        #expect(store.lastKnownResetSnapshots[.kilo] == nil)
        #expect(store.kiloScopeSnapshots.isEmpty)
        #expect(store.providerStorageFootprints[.kilo] == nil)
        #expect(store.quotaWarningState[
            UsageStore.QuotaWarningStateKey(provider: .kilo, window: .session, accountDiscriminator: nil),
        ] == nil)
        #expect(store.predictivePaceWarningNotifiedKeys.allSatisfy { $0.provider != .kilo })
        #expect(store.lastTokenFetchAt[.kilo] == nil)
        #expect(store.lastTokenFetchScope[.kilo] == nil)

        #expect(store.lastKnownResetSnapshots[.codex]?.primary?.usedPercent == 12)
        #expect(store.quotaWarningState[
            UsageStore.QuotaWarningStateKey(provider: .codex, window: .session, accountDiscriminator: nil),
        ] != nil)
        #expect(store.predictivePaceWarningNotifiedKeys.contains { $0.provider == .codex })
    }

    @Test
    func `disabled Codex cleanup clears account snapshots and publication guard`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-codex")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        let account = CodexVisibleAccount(
            id: "stale@example.com",
            email: "stale@example.com",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: true)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 33, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store.lastKnownResetSnapshots[.codex] = snapshot
        store.codexAccountSnapshots = [
            CodexAccountUsageSnapshot(account: account, snapshot: snapshot, error: nil, sourceLabel: "stale"),
        ]
        store.lastCodexUsagePublicationGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .emailOnly(normalizedEmail: "stale@example.com"),
            accountKey: "stale@example.com",
            authFingerprint: "stale-fingerprint")
        store.lastCodexAccountScopedRefreshGuard = store.lastCodexUsagePublicationGuard

        store.clearDisabledProviderState(enabledProviders: Set(store.enabledProvidersForDisplay()))

        #expect(store.snapshot(for: .codex) == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.codexAccountSnapshots.isEmpty)
        #expect(store.lastCodexUsagePublicationGuard == nil)
        #expect(store.lastCodexAccountScopedRefreshGuard != nil)
    }

    @Test
    func `disabled Claude cleanup clears swap runtime without touching settings`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-claude-swap")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.claudeSwapEnabled = true
        settings.claudeSwapExecutablePath = "/tmp/cswap-fixture"

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        store.claudeSwapAccountSnapshots = [
            ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "1"),
                provider: .claude,
                displayLabel: "account@example.com",
                isActive: false,
                snapshot: nil,
                error: "Token expired",
                sourceLabel: ClaudeSwapAccountProjection.sourceLabel),
        ]
        store.claudeSwapLastRefreshAt = Date()
        store.claudeSwapLastError = "stale"

        store.clearDisabledProviderState(enabledProviders: Set(store.enabledProvidersForDisplay()))

        #expect(store.claudeSwapAccountSnapshots.isEmpty)
        #expect(store.claudeSwapLastRefreshAt == nil)
        #expect(store.claudeSwapLastError == nil)
        #expect(settings.claudeSwapEnabled)
        #expect(settings.claudeSwapExecutablePath == "/tmp/cswap-fixture")
    }

    @Test
    func `unavailable provider cleanup clears derived reset and scope state`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-unavailable")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .kilo, metadata: #require(metadata[.kilo]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        let staleSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 55, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(staleSnapshot, provider: .kilo)
        store.lastKnownResetSnapshots[.kilo] = staleSnapshot
        store.kiloScopeSnapshots = [
            KiloScopeSnapshot(
                id: KiloUsageScope.personal.scopeIdentifier,
                scope: .personal,
                snapshot: staleSnapshot,
                errorMessage: nil,
                sourceLabel: "personal"),
            KiloScopeSnapshot(
                id: "org-stale",
                scope: .organization(id: "org-stale", name: "Stale Org"),
                snapshot: staleSnapshot,
                errorMessage: nil,
                sourceLabel: "org"),
        ]

        store.clearUnavailableProviderState(
            displayEnabledProviders: [.kilo],
            availableProviders: [])

        #expect(store.snapshot(for: .kilo) == nil)
        #expect(store.lastKnownResetSnapshots[.kilo] == nil)
        #expect(store.kiloScopeSnapshots.isEmpty)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        return settings
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
    }

    private static func setOnlyProvider(
        _ provider: UsageProvider,
        enabled: Bool,
        settings: SettingsStore) throws
    {
        let metadata = ProviderRegistry.shared.metadata
        for candidate in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: candidate,
                metadata: #require(metadata[candidate]),
                enabled: candidate == provider && enabled)
        }
    }

    private static func setProvider(
        _ provider: UsageProvider,
        enabled: Bool,
        settings: SettingsStore) throws
    {
        try settings.setProviderEnabled(
            provider: provider,
            metadata: #require(ProviderRegistry.shared.metadata[provider]),
            enabled: enabled)
    }

    private static func usageSnapshot(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
    }

    private static func providerOutcome(snapshot: UsageSnapshot) -> ProviderFetchOutcome {
        ProviderFetchOutcome(
            result: .success(ProviderFetchResult(
                usage: snapshot,
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "fixture",
                strategyKind: .cli)),
            attempts: [])
    }

    private static func tokenSnapshot(
        tokens: Int,
        historyDays: Int,
        updatedAt: Date = Date()) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: 1,
            last30DaysTokens: tokens,
            last30DaysCostUSD: 1,
            historyDays: historyDays,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-11",
                    inputTokens: tokens,
                    outputTokens: 0,
                    totalTokens: tokens,
                    costUSD: 1,
                    modelsUsed: [],
                    modelBreakdowns: nil),
            ],
            updatedAt: updatedAt)
    }
}

private enum CleanupTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "fixture failure"
    }
}

private actor CleanupAsyncGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        self.started = true
        for waiter in self.startWaiters {
            waiter.resume()
        }
        self.startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func resume() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}
