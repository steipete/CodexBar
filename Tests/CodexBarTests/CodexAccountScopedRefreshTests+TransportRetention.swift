import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    @Test
    func `ordinary Codex refresh retains usage and widget timestamps during localized outages`() async throws {
        let (store, prior, owner) = self.makeCodexTransportRetentionStore(suite: "retains-prior")
        let transport = self.installCodexRetentionTransport(on: store)
        var saved: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { saved.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        #expect(!store.shouldFetchAllCodexVisibleAccounts())
        #expect(owner.identity == .providerAccount(id: "acct-retained"))
        #expect(store.shouldApplyCodexScopedFailure(expectedGuard: owner))
        store.persistWidgetSnapshot(reason: "before-codex-transport-failure")
        await store.widgetSnapshotPersistTask?.value
        let originalEntry = try #require(saved.last?.entries.first { $0.provider == .codex })
        #expect(originalEntry.primary == prior.primary)
        #expect(originalEntry.updatedAt == prior.updatedAt)

        await store.refreshProvider(.codex, allowDisabled: true)
        #expect(store.snapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.errors[.codex] == nil)
        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(await transport.requests().count == 2)
        #expect(store.snapshots[.codex]?.primary == prior.primary)
        #expect(store.snapshots[.codex]?.secondary == prior.secondary)
        #expect(store.snapshots[.codex]?.updatedAt == prior.updatedAt)
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "retained@example.com")
        #expect(store.errors[.codex] == "Network error: Verbindung fehlgeschlagen")
        #expect(store.lastCodexUsagePublicationGuard == owner)
        #expect(store.freshCodexAccountScopedRefreshGuard() == owner)

        store.persistWidgetSnapshot(reason: "after-codex-transport-failure")
        await store.widgetSnapshotPersistTask?.value
        let retainedEntry = try #require(saved.last?.entries.first { $0.provider == .codex })
        #expect(retainedEntry.primary == originalEntry.primary)
        #expect(retainedEntry.secondary == originalEntry.secondary)
        #expect(retainedEntry.usageRows == originalEntry.usageRows)
        #expect(retainedEntry.updatedAt == prior.updatedAt)
    }

    @Test
    func `ordinary Codex transport failure without prior usage cannot create a widget entry`() async {
        let (store, _, owner) = self.makeCodexTransportRetentionStore(suite: "no-prior", hasPriorUsage: false)
        let transport = self.installCodexRetentionTransport(on: store)
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        await store.refreshProvider(.codex, allowDisabled: true)
        await store.refreshProvider(.codex, allowDisabled: true)
        #expect(await transport.requests().count == 2)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == "Network error: Verbindung fehlgeschlagen")
        #expect(store.freshCodexAccountScopedRefreshGuard() == owner)

        store.persistWidgetSnapshot(reason: "codex-transport-no-prior")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.contains { $0.provider == .codex } == false)
    }

    @Test
    func `ordinary Codex authentication failure still removes prior usage and widget entry`() async {
        let (store, _, owner) = self.makeCodexTransportRetentionStore(suite: "auth-failure")
        let transport = self.installCodexRetentionTransport(on: store, statusCode: 401)
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }
        store.persistWidgetSnapshot(reason: "before-codex-auth-failure")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.contains { $0.provider == .codex } == true)

        await store.refreshProvider(.codex, allowDisabled: true)
        await store.refreshProvider(.codex, allowDisabled: true)
        #expect(await transport.requests().count == 2)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == CodexOAuthFetchError.unauthorized.localizedDescription)
        #expect(store.freshCodexAccountScopedRefreshGuard() == owner)

        store.persistWidgetSnapshot(reason: "after-codex-auth-failure")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.contains { $0.provider == .codex } == false)
    }

    @Test
    func `ordinary Codex transport failure cannot retain usage after account changes`() async {
        let (store, _, owner) = self.makeCodexTransportRetentionStore(suite: "account-change")
        let transport = self.installCodexRetentionTransport(on: store)
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }
        store.persistWidgetSnapshot(reason: "before-codex-account-change")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.contains { $0.provider == .codex } == true)

        store.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "next@example.com",
            workspaceAccountID: "acct-next",
            codexHomePath: CodexCredentialFixtures.root.appendingPathComponent(".codex").path,
            observedAt: Date(),
            identity: .providerAccount(id: "acct-next"))
        #expect(!store.shouldApplyCodexScopedFailure(expectedGuard: owner))
        await store.refreshProvider(.codex, allowDisabled: true)
        await store.refreshProvider(.codex, allowDisabled: true)
        #expect(await transport.requests().count == 2)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.lastCodexUsagePublicationGuard?.identity == .providerAccount(id: "acct-next"))
        #expect(store.errors[.codex] == "Network error: Verbindung fehlgeschlagen")

        store.persistWidgetSnapshot(reason: "after-codex-account-change")
        await store.widgetSnapshotPersistTask?.value
        #expect(saved?.entries.contains { $0.provider == .codex } == false)
    }

    private func makeCodexTransportRetentionStore(
        suite: String,
        hasPriorUsage: Bool = true) -> (UsageStore, UsageSnapshot, CodexAccountScopedRefreshGuard)
    {
        let settings = self.makeSettingsStore(suite: "CodexTransportRetention-\(suite)")
        settings.refreshFrequency = .manual
        settings.codexUsageDataSource = .oauth
        settings.codexCookieSource = .off
        settings.multiAccountMenuLayout = .segmented
        settings.codexActiveSource = .liveSystem
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "retained@example.com",
            workspaceAccountID: "acct-retained",
            codexHomePath: CodexCredentialFixtures.root.appendingPathComponent(".codex").path,
            observedAt: Date(),
            identity: .providerAccount(id: "acct-retained"))
        let store = self.makeUsageStore(settings: settings)
        let prior = UsageSnapshot(
            primary: RateWindow(usedPercent: 17, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 31, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_789_473_600),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "retained@example.com",
                accountOrganization: nil,
                loginMethod: "Pro",
                accountID: "acct-retained"))
        if hasPriorUsage {
            store._setSnapshotForTesting(prior, provider: .codex)
            store.lastKnownResetSnapshots[.codex] = prior
            store.lastSourceLabels[.codex] = "oauth"
        }
        let owner = store.freshCodexAccountScopedRefreshGuard()
        store.lastCodexUsagePublicationGuard = owner
        store.lastCodexAccountScopedRefreshGuard = owner
        return (store, prior, owner)
    }

    private func installCodexRetentionTransport(on store: UsageStore, statusCode: Int? = nil)
        -> ProviderHTTPTransportStub
    {
        let transport = ProviderHTTPTransportStub { request in
            guard let statusCode else {
                throw NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorCannotFindHost,
                    userInfo: [NSLocalizedDescriptionKey: "Verbindung fehlgeschlagen"])
            }
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
            return (Data("{}".utf8), response)
        }
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { context in
            _ = try await CodexOAuthUsageFetcher.fetchUsage(
                accessToken: "fixture-access",
                accountId: "acct-retained",
                env: context.env,
                session: transport)
            throw TestRefreshError(message: "Fixture transport unexpectedly succeeded")
        }
        return transport
    }
}
