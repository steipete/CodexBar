import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    @Test
    func `credits refresh honors explicit codex oauth source without raw CLI fallback`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-oauth-credits-source")
        settings.refreshFrequency = .manual
        settings.codexUsageDataSource = .oauth
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(
            settings: settings,
            environmentBase: ["CODEX_CLI_PATH": "/missing/codex"])
        let usage = self.codexSnapshot(email: "alpha@example.com", usedPercent: 10)
        store._setSnapshotForTesting(usage, provider: .codex)

        let oauthStrategy = TestCodexFetchStrategy(
            loader: { usage },
            credits: self.credits(remaining: 77),
            id: "codex.oauth",
            kind: .oauth,
            sourceLabel: "codex.oauth")
        let cliStrategy = ThrowingTestCodexFetchStrategy {
            throw TestRefreshError(message: "CLI strategy should not run for explicit OAuth credits refresh")
        }
        let baseSpec = try #require(store.providerSpecs[.codex])
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) { context in
            switch context.sourceMode {
            case .oauth:
                [oauthStrategy]
            case .cli:
                [cliStrategy]
            case .auto:
                [oauthStrategy, cliStrategy]
            case .web, .api:
                []
            }
        }

        await store.refreshCreditsIfNeeded()

        #expect(store.credits?.remaining == 77)
        #expect(store.lastCreditsError == nil)
        #expect(store.lastCreditsSource == .api)
    }

    @Test
    func `auto credits refresh falls back when oauth usage omits credits`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-auto-credits-fallback")
        settings.refreshFrequency = .manual
        settings.codexUsageDataSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "alpha@example.com")

        let store = self.makeUsageStore(settings: settings)
        let usage = self.codexSnapshot(email: "alpha@example.com", usedPercent: 10)
        store._setSnapshotForTesting(usage, provider: .codex)

        let oauthStrategy = TestCodexFetchStrategy(
            loader: { usage },
            credits: nil,
            id: "codex.oauth",
            kind: .oauth,
            sourceLabel: "codex.oauth")
        let cliStrategy = TestCodexFetchStrategy(
            loader: { usage },
            credits: self.credits(remaining: 41),
            id: "codex.cli",
            kind: .cli,
            sourceLabel: "codex.cli")
        let baseSpec = try #require(store.providerSpecs[.codex])
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) { context in
            switch context.sourceMode {
            case .auto:
                [oauthStrategy, cliStrategy]
            case .oauth:
                [oauthStrategy]
            case .cli:
                [cliStrategy]
            case .web, .api:
                []
            }
        }

        await store.refreshCreditsIfNeeded()

        #expect(store.credits?.remaining == 41)
        #expect(store.lastCreditsError == nil)
        #expect(store.lastCreditsSource == .api)
    }

    @Test
    func `enrichment failure reattaches preserved monthly cap to account and selected usage`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-reattach-preserved-monthly-cap")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings.setMenuBarMetricPreference(.extraUsage, for: .codex)
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "biz@example.com")
        settings.codexActiveSource = .liveSystem

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        settings._test_managedCodexAccountStoreURL = managedStoreURL
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: managedStoreURL)
        }

        let liveAccount = try #require(settings.codexVisibleAccountProjection.visibleAccounts.first {
            $0.email == "biz@example.com"
        })
        let usage = self.codexSnapshot(email: liveAccount.email, usedPercent: 12)
        let priorCredits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: Date(),
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 27,
                limit: 1000,
                remainingPercent: 97.3,
                resetsAt: nil,
                updatedAt: Date()))
        let priorSnapshots = settings.codexVisibleAccountProjection.visibleAccounts.map { account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: self.codexSnapshot(email: account.email, usedPercent: 17),
                error: nil,
                sourceLabel: "cached",
                credits: account.id == liveAccount.id ? priorCredits : nil)
        }
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = self.makeUsageStore(
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore)
        store._test_codexResetCreditsFetcherOverride = { _ in nil }

        let strategy = TestCodexFetchStrategy(
            loader: { usage },
            credits: nil,
            id: "stacked-test",
            kind: .apiToken,
            sourceLabel: "api",
            codexMonthlyLimitEnrichmentFailed: true)
        let baseSpec = try #require(store.providerSpecs[.codex])
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) { _ in
            [strategy]
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let accountSnapshot = try #require(store.codexAccountSnapshots.first { $0.id == liveAccount.id })
        #expect(accountSnapshot.credits?.codexCreditLimit?.used == 27)
        #expect(accountSnapshot.snapshot?.providerCost?.used == 27)
        #expect(accountSnapshot.snapshot?.providerCost?.limit == 1000)

        let published = try #require(store.snapshots[.codex])
        #expect(published.providerCost?.used == 27)
        #expect(published.providerCost?.limit == 1000)
        #expect(settings.menuBarMetricPreference(for: .codex, snapshot: published) == .extraUsage)
        #expect(abs((store.codexMenuBarMetricWindow(snapshot: published)?.usedPercent ?? 0) - 2.7) < 0.0001)
    }
}
