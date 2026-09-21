import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct WidgetTokenOwnerTests {
    private let measuredAt = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func `rotating credentials requires new verification but preserves a verified owner pin`() throws {
        let (settings, store) = self.makeStore()
        let account = settings.tokenAccounts(for: .claude)[0]
        self.publish(account, to: store, owner: "owner-a")
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        settings.updateTokenAccount(provider: .claude, accountID: account.id, token: "rotated-fixture-token")
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
        let rotated = settings.tokenAccounts(for: .claude)[0]
        self.publish(rotated, to: store, owner: "owner-a", percent: 40)
        let verified = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        #expect(verified.id == original.id)
        #expect(verified.usage?.primary?.usedPercent == 40)
        self.publish(rotated, to: store, owner: "replacement-owner", percent: 80)
        let replaced = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        #expect(replaced.id != original.id)
        #expect(replaced.usage?.primary?.usedPercent == 80)
    }

    @Test
    func `profile failure retains verified quota age but authentication failure removes it`() throws {
        let (settings, store) = self.makeStore()
        let account = settings.tokenAccounts(for: .claude)[0]
        self.publish(account, to: store, owner: "owner-a")
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        self.publish(account, to: store, owner: nil, percent: 80, at: self.measuredAt.addingTimeInterval(600))
        let retained = try #require(store.makeWidgetAccountEntries(now: self.measuredAt.addingTimeInterval(600)).first)
        #expect(retained.id == original.id)
        #expect(retained.usage?.primary?.usedPercent == 20)
        #expect(retained.usage?.updatedAt == self.measuredAt)
        store.accountSnapshots[.claude] = [TokenAccountUsageSnapshot(
            account: account,
            snapshot: nil,
            error: "401 Unauthorized",
            sourceLabel: "fixture",
            cacheKey: store.tokenAccountSnapshotCacheKey(provider: .claude, account: account))]
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
        self.publish(account, to: store, owner: nil)
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
    }

    @Test
    func `display labels cannot establish ownership and renaming does not invalidate a verified pin`() throws {
        let (settings, store) = self.makeStore()
        let account = settings.tokenAccounts(for: .claude)[0]
        self.publish(account, to: store, owner: nil)
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
        self.publish(account, to: store, owner: "owner-a")
        let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        settings.updateTokenAccount(provider: .claude, accountID: account.id, label: "Renamed private label")
        let renamed = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        #expect(renamed.id == original.id)
        #expect(renamed.label == "Renamed private label")
        settings.hidePersonalInfo = true
        let hidden = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
        #expect(hidden.id == original.id)
        #expect(hidden.label == "Account 1")
        let data = try #require(String(data: JSONEncoder().encode(hidden), encoding: .utf8))
        #expect(!data.contains("private"))
        #expect(!data.contains("fixture-token"))
        #expect(!data.contains("owner-a"))
        #expect(!data.contains("@example.com"))
    }

    @Test
    func `explicit usage organization and workspace scope changes invalidate old quota and pins`() throws {
        for field in ["usage", "organization", "workspace"] {
            let (settings, store) = self.makeStore()
            let account = settings.tokenAccounts(for: .claude)[0]
            self.publish(account, to: store, owner: "owner-a")
            let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
            settings.updateTokenAccount(
                provider: .claude,
                accountID: account.id,
                usageScope: field == "usage" ? .some("organization") : nil,
                organizationID: field == "organization" ? .some("org-b") : nil,
                workspaceID: field == "workspace" ? .some("workspace-b") : nil)
            #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
            self.publish(settings.tokenAccounts(for: .claude)[0], to: store, owner: "owner-a")
            #expect(store.makeWidgetAccountEntries(now: self.measuredAt).first?.id != original.id)
        }
    }

    @Test
    func `opt out and removal clear verified retention and cap includes the selected seventh account`() {
        let (settings, store) = self.makeStore()
        for index in 2...7 {
            settings.addTokenAccount(provider: .claude, label: "Account \(index)", token: "fixture-token-\(index)")
        }
        let accounts = settings.tokenAccounts(for: .claude)
        for (index, account) in accounts.enumerated() {
            self.publish(account, to: store, owner: "owner-\(index)")
        }
        let entries = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(entries.count == 6)
        #expect(entries.contains { $0.label == "Account 7" })
        #expect(!entries.contains { $0.label == "Account 6" })
        #expect(store.widgetVerifiedTokenSnapshots[.claude]?.count == 6)
        settings.removeTokenAccount(provider: .claude, accountID: accounts[0].id)
        let afterRemoval = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(!afterRemoval.contains { $0.id == entries[0].id })
        settings.accountWidgetsEnabled = false
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
        #expect(store.widgetVerifiedTokenSnapshots.isEmpty)
        store.accountSnapshots = [:]
        settings.accountWidgetsEnabled = true
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
    }

    @Test
    func `duplicate saved account or cached snapshot IDs cannot publish a first match`() throws {
        let (settings, store) = self.makeStore()
        let account = settings.tokenAccounts(for: .claude)[0]
        self.publish(account, to: store, owner: "owner-a")
        let cached = try #require(store.accountSnapshots[.claude]?.first)
        store.accountSnapshots[.claude] = [cached, cached]
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
        store.accountSnapshots[.claude] = [cached]
        settings.updateProviderConfig(provider: .claude) { config in
            config.tokenAccounts = ProviderTokenAccountData(version: 1, accounts: [account, account], activeIndex: 0)
        }
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
    }

    @Test
    func `identity context requests require both opt in and a selected saved account`() throws {
        let (settings, store) = self.makeStore()
        let account = settings.tokenAccounts(for: .claude)[0]
        settings.accountWidgetsEnabled = false
        #expect(!store.makeFetchContext(provider: .claude, override: nil).includeAccountIdentity)
        #expect(try !#require(store.providerSpecs[.claude]).makeFetchContext().includeAccountIdentity)
        settings.accountWidgetsEnabled = true
        #expect(store.makeFetchContext(provider: .claude, override: nil).includeAccountIdentity)
        #expect(try (#require(store.providerSpecs[.claude])).makeFetchContext().includeAccountIdentity)
        settings.removeTokenAccount(provider: .claude, accountID: account.id)
        #expect(!store.makeFetchContext(provider: .claude, override: nil).includeAccountIdentity)
        #expect(try !#require(store.providerSpecs[.claude]).makeFetchContext().includeAccountIdentity)
    }

    @Test
    func `clearing provider runtime cannot revive earlier verified quotas`() {
        let (settings, store) = self.makeStore()
        let account = settings.tokenAccounts(for: .claude)[0]
        self.publish(account, to: store, owner: "owner-a")
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).count == 1)
        store.clearProviderRuntimeState(.claude)
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
        self.publish(account, to: store, owner: nil)
        #expect(store.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
    }

    @Test
    func `verified widget ownership leaves cloud records hooks and serialized identity unchanged`() throws {
        let (settings, store) = self.makeStore()
        let account = settings.tokenAccounts(for: .claude)[0]
        let original = ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            opus: nil,
            updatedAt: self.measuredAt,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Pro",
            rawText: nil)
        let snapshots = [original, original.withAccountIdentity("verified-owner"), original].map {
            ClaudeOAuthFetchStrategy._snapshotForTesting(from: $0).withAccountLabel(account.label, for: .claude)
        }
        var cloudNames: [[String]] = []
        var hookIDs: [String?] = []
        var encoded: [Data] = []
        for snapshot in snapshots {
            store.cacheTokenAccountSnapshot(
                provider: .claude,
                account: account,
                snapshot: snapshot,
                sourceLabel: "fixture")
            cloudNames.append(store.cloudSyncAccountSnapshots().map(\.recordName).sorted())
            hookIDs.append(UsageStore.hookAccountDiscriminator(provider: .claude, snapshot: snapshot))
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try encoded.append(encoder.encode(snapshot.identity))
        }
        #expect(cloudNames[0] == cloudNames[1] && cloudNames[1] == cloudNames[2])
        #expect(hookIDs[0] == hookIDs[1] && hookIDs[1] == hookIDs[2])
        #expect(encoded[0] == encoded[1] && encoded[1] == encoded[2])
        #expect(snapshots[1].identity?.widgetAccountOwnerID == "verified-owner")
        let decoded = try JSONDecoder().decode(ProviderIdentitySnapshot.self, from: encoded[1])
        #expect(decoded.widgetAccountOwnerID == nil)
        #expect(snapshots[1].identity?.scoped(to: UsageProvider.codex).widgetAccountOwnerID == nil)
    }

    @Test
    func `saved account fanout verifies each winning token and publishes isolated quota`() async {
        let (settings, store) = self.makeStore()
        let account = settings.tokenAccounts(for: .claude)[0]
        settings.updateTokenAccount(provider: .claude, accountID: account.id, token: "sk-ant-oat01-fixture-work")
        settings.addTokenAccount(provider: .claude, label: "Personal", token: "sk-ant-oat01-fixture-personal")
        settings.multiAccountMenuLayout = .segmented
        let calls = WidgetIdentityCalls()
        let credentials: @Sendable ([String: String], Bool, Bool) async throws -> ClaudeOAuthCredentials =
            { environment, _, _ in
                let token = try #require(environment[ClaudeOAuthCredentialsStore.environmentTokenKey])
                return ClaudeOAuthCredentials(
                    accessToken: token,
                    refreshToken: nil,
                    expiresAt: Date().addingTimeInterval(3600),
                    scopes: ["user:profile"],
                    rateLimitTier: "claude_pro")
            }
        let usage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { token, _ in
            await calls.append("usage:\(token)")
            let percent = token == "sk-ant-oat01-fixture-work" ? 21 : 73
            return try JSONDecoder().decode(
                OAuthUsageResponse.self, from: Data("{\"five_hour\":{\"utilization\":\(percent)}}".utf8))
        }
        let profile: @Sendable (String) async throws -> OAuthProfileResponse = { token in
            await calls.append("profile:\(token)")
            return OAuthProfileResponse(emailAddress: nil, organizationUuid: "org", accountUuid: token)
        }
        await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(credentials) {
            await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(usage) {
                await ClaudeUsageFetcher.$fetchOAuthProfileOverride.withValue(profile) {
                    await store.refreshProvider(.claude)
                }
            }
        }
        let entries = store.makeWidgetAccountEntries(now: self.measuredAt)
        #expect(entries.map { $0.usage?.primary?.usedPercent } == [21, 73])
        #expect(Set(entries.map(\.id)).count == 2)
        #expect(entries.map(\.label) == ["Private Work", "Personal"])
        #expect(await calls.values.sorted() == [
            "profile:sk-ant-oat01-fixture-personal", "profile:sk-ant-oat01-fixture-work",
            "usage:sk-ant-oat01-fixture-personal", "usage:sk-ant-oat01-fixture-work",
        ])
    }

    private func makeStore(
        snapshotStore: (any WidgetAccountSnapshotStoring)? = nil) -> (SettingsStore, UsageStore)
    {
        let settings = testSettingsStore(suiteName: "WidgetTokenOwnerTests", userDefaults: InMemoryUserDefaults())
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        enableTestProviders([.claude], settings: settings)
        settings.accountWidgetsEnabled = true
        settings.addTokenAccount(provider: .claude, label: "Private Work", token: "fixture-token-work")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetAccountSnapshotStore: snapshotStore,
            widgetTimelineReloader: {})
        return (settings, store)
    }

    @Test
    func `refresh after a label edit retains verified data only for retryable failures`() async throws {
        let failures: [(any Error, Bool)] = [
            (ClaudeOAuthFetchError.networkError(URLError(.timedOut)), true),
            (ClaudeOAuthFetchError.networkError(URLError(.notConnectedToInternet)), true),
            (ClaudeOAuthFetchError.unauthorized, false),
        ]
        for (failure, preserves) in failures {
            let (settings, store) = self.makeStore()
            let id = settings.tokenAccounts(for: .claude)[0].id
            settings.updateTokenAccount(provider: .claude, accountID: id, token: "sk-ant-oat01-fixture-work")
            let account = settings.tokenAccounts(for: .claude)[0]
            self.publish(account, to: store, owner: "verified-owner")
            let original = try #require(store.makeWidgetAccountEntries(now: self.measuredAt).first)
            settings.updateTokenAccount(provider: .claude, accountID: id, label: "Renamed")
            let credentials: @Sendable ([String: String], Bool, Bool) async throws -> ClaudeOAuthCredentials =
                { environment, _, _ in
                    ClaudeOAuthCredentials(
                        accessToken: environment[ClaudeOAuthCredentialsStore.environmentTokenKey]!,
                        refreshToken: nil,
                        expiresAt: Date().addingTimeInterval(3600),
                        scopes: ["user:profile"],
                        rateLimitTier: "claude_pro")
                }
            let usage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { _, _ in throw failure }
            await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(credentials) {
                await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(usage) {
                    await store.refreshProvider(.claude)
                }
            }
            let current = try #require(store.accountSnapshots[.claude]?.first)
            #expect(current.snapshot == nil)
            #expect(current.fetchError != nil)
            let result = store.makeWidgetAccountEntries(now: self.measuredAt.addingTimeInterval(600))
            if preserves {
                let retained = try #require(result.first)
                #expect(retained.id == original.id)
                #expect(retained.label == "Renamed")
                #expect(retained.usage?.primary?.usedPercent == 20)
                #expect(retained.usage?.updatedAt == self.measuredAt)
            } else {
                #expect(result.isEmpty)
            }
        }
    }

    @Test
    func `private quota cache survives offline restarts and rejects replaced credentials`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("widget-private-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("accounts.json")
        let (settings, first) = self.makeStore(snapshotStore: FileWidgetAccountSnapshotStore(url: url))
        let account = settings.tokenAccounts(for: .claude)[0]
        self.publish(account, to: first, owner: "verified-owner")
        let original = try #require(first.makeWidgetAccountEntries(now: self.measuredAt).first)
        let data = try String(contentsOf: url, encoding: .utf8)
        #expect(!data.contains(account.token))
        #expect(!data.contains(account.label))
        #expect(!data.contains("label-spoof@example.com"))
        #expect(!data.contains("verified-owner"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        settings.hidePersonalInfo = true
        let restarted = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetAccountSnapshotStore: FileWidgetAccountSnapshotStore(url: url),
            widgetTimelineReloader: {})
        restarted.accountSnapshots[.claude] = [TokenAccountUsageSnapshot(
            account: account,
            snapshot: nil,
            error: "Network unavailable",
            sourceLabel: nil,
            cacheKey: restarted.tokenAccountSnapshotCacheKey(provider: .claude, account: account),
            fetchError: URLError(.notConnectedToInternet))]
        let retained = try #require(restarted.makeWidgetAccountEntries(now: self.measuredAt.addingTimeInterval(600))
            .first)
        #expect(retained.id == original.id)
        #expect(retained.label == "Account 1")
        #expect(retained.usage?.updatedAt == self.measuredAt)
        #expect(retained.usage?.primary?.usedPercent == 20)
        let shared = try #require(String(data: JSONEncoder().encode(retained), encoding: .utf8))
        #expect(!shared.contains("credentialScope"))
        #expect(!shared.contains(account.token))
        settings.updateTokenAccount(provider: .claude, accountID: account.id, token: "replacement-token")
        #expect(restarted.makeWidgetAccountEntries(now: self.measuredAt).isEmpty)
        #expect(FileWidgetAccountSnapshotStore(url: url).load().isEmpty)
    }

    private func publish(
        _ account: ProviderTokenAccount,
        to store: UsageStore,
        owner: String?,
        percent: Double = 20,
        at date: Date? = nil)
    {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: percent, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: date ?? self.measuredAt,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "label-spoof@example.com",
                accountOrganization: nil,
                loginMethod: "Pro",
                widgetAccountOwnerID: owner))
        store.cacheTokenAccountSnapshot(provider: .claude, account: account, snapshot: snapshot, sourceLabel: "fixture")
    }
}

private actor WidgetIdentityCalls {
    var values: [String] = []
    func append(_ value: String) { self.values.append(value) }
}
