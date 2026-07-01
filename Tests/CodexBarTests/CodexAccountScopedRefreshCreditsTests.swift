import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    @Test
    func `stacked codex account refresh keeps reset credits scoped to each account`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-reset-credits")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings.showOptionalCreditsAndExtraUsage = true

        let liveHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: liveHome,
            email: "live@example.com",
            plan: "pro",
            accountId: "acct-live")
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "managed@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: liveHome)
            try? FileManager.default.removeItem(at: managedHome)
            try? FileManager.default.removeItem(at: managedStoreURL)
        }

        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: liveHome.path,
            observedAt: Date(),
            identity: .providerAccount(id: "acct-live"))
        settings.codexActiveSource = .liveSystem

        let store = self.makeUsageStore(settings: settings)
        self.installContextualCodexProvider(on: store) { context in
            let email = context.env["CODEX_HOME"] == liveHome.path
                ? "live@example.com"
                : "managed@example.com"
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 12,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: email,
                    accountOrganization: nil,
                    loginMethod: "Pro"))
        }
        store._test_codexResetCreditsFetcherOverride = { env in
            guard let home = env["CODEX_HOME"] else { return nil }
            let now = Date()
            return CodexRateLimitResetCreditsSnapshot(
                credits: [
                    CodexRateLimitResetCredit(
                        id: URL(fileURLWithPath: home).lastPathComponent,
                        resetType: "codex_rate_limits",
                        status: .available,
                        grantedAt: now,
                        expiresAt: now.addingTimeInterval(86400),
                        redeemStartedAt: nil,
                        redeemedAt: nil,
                        title: "One free rate limit reset",
                        description: nil),
                ],
                availableCount: 1,
                updatedAt: now)
        }
        defer { store._test_codexResetCreditsFetcherOverride = nil }

        await store.refreshCodexVisibleAccountsForMenu()

        #expect(store.codexAccountSnapshots.count == 2)
        for accountSnapshot in store.codexAccountSnapshots {
            let expectedCreditID = switch accountSnapshot.account.selectionSource {
            case .liveSystem:
                liveHome.lastPathComponent
            case .managedAccount:
                managedHome.lastPathComponent
            case .profileHome:
                "unexpected-profile"
            }
            #expect(accountSnapshot.snapshot?.codexResetCredits?.credits.first?.id == expectedCreditID)
        }
    }

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
}
