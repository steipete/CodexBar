import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized, CodexCredentialFixtures())
struct CodexProfileHomeAccountTests {
    @MainActor
    private static func makeSettings(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        return settings
    }

    @Test
    @MainActor
    func `settings store discovers configured codex profile homes`() throws {
        let suite = "CodexProfileHomeAccountTests-discovery"
        let settings = try Self.makeSettings(suite: suite)
        let missingLiveHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let profileHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: profileHome,
            email: "Profile@Example.com",
            plan: "pro",
            accountID: "acct_profile")
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": missingLiveHome.path]
        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = [profileHome.path, profileHome.path]
        }
        settings.codexActiveSource = .profileHome(path: profileHome.path)
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: missingLiveHome)
            try? FileManager.default.removeItem(at: profileHome)
        }

        let normalizedProfilePath = try #require(CodexHomeScope.normalizedHomePath(profileHome.path))
        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(settings.codexResolvedActiveSource == .profileHome(path: normalizedProfilePath))
        #expect(snapshot.liveSystemAccount == nil)
        #expect(snapshot.profileHomeAccounts.map(\.email) == ["profile@example.com"])
        #expect(snapshot.profileHomeAccounts.map(\.codexHomePath) == [normalizedProfilePath])
        #expect(snapshot.profileHomePaths == [normalizedProfilePath])
        #expect(projection.visibleAccounts.map(\.email) == ["profile@example.com"])
        #expect(projection.activeVisibleAccountID == "profile@example.com")
        #expect(projection.liveVisibleAccountID == nil)
        #expect(projection.visibleAccounts.first?.selectionSource == .profileHome(path: normalizedProfilePath))
        #expect(projection.visibleAccounts.first?.isLive == false)
        #expect(projection.visibleAccounts.first?.canReauthenticate == false)
        #expect(projection.visibleAccounts.first?.canRemove == false)
    }

    @Test
    @MainActor
    func `provider registry scopes selected codex profile home`() throws {
        let suite = "CodexProfileHomeAccountTests-routing"
        let settings = try Self.makeSettings(suite: suite)
        let profileHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: profileHome,
            email: "profile-route@example.com",
            plan: "pro")
        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = [profileHome.path]
            entry.codexActiveSource = .profileHome(path: profileHome.path)
        }
        defer {
            try? FileManager.default.removeItem(at: profileHome)
        }

        let normalizedProfilePath = try #require(CodexHomeScope.normalizedHomePath(profileHome.path))
        let environment = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": "/tmp/ambient-codex"],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(environment["CODEX_HOME"] == normalizedProfilePath)
    }

    @Test
    @MainActor
    func `profile home selection immediately hides the previous account cost dashboard`() throws {
        let fixture = try Self.makeProfileHomeCostFixture(suite: "CodexProfileHomeAccountTests-cost-selection")
        defer { fixture.cleanup() }

        let profileASnapshot = Self.costSnapshot(cost: 12, tokens: 1200, model: "fictional-profile-a")
        fixture.store._setTokenSnapshotForTesting(profileASnapshot, provider: .codex)
        let originalModel = ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_menuCardModel(for: .codex)

        #expect(originalModel.tokenUsage?.sessionLine.contains("$12") == true)
        #expect(originalModel.inlineUsageDashboard?.points.isEmpty == false)
        #expect(originalModel.inlineUsageDashboard?.detailLines.contains { $0.contains("fictional-profile-a") } == true)

        fixture.settings.selectDisplayedCodexVisibleAccount(fixture.secondAccount)

        let switchedModel = ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_menuCardModel(for: .codex)

        #expect(fixture.store.tokenSnapshots[.codex] == profileASnapshot)
        #expect(fixture.store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
        #expect(fixture.store.tokenSnapshot(for: .codex) == nil)
        #expect(switchedModel.email == "profile-b@example.com")
        #expect(switchedModel.tokenUsage == nil)
        #expect(switchedModel.inlineUsageDashboard == nil)
    }

    @Test
    @MainActor
    func `profile home transition clears only codex cost state and preserves unrelated providers`() throws {
        let fixture = try Self.makeProfileHomeCostFixture(suite: "CodexProfileHomeAccountTests-cost-invalidation")
        defer { fixture.cleanup() }

        let codexSnapshot = Self.costSnapshot(cost: 12, tokens: 1200, model: "fictional-profile-a")
        let claudeSnapshot = Self.costSnapshot(cost: 34, tokens: 3400, model: "fictional-claude")
        fixture.store._setTokenSnapshotForTesting(codexSnapshot, provider: .codex)
        fixture.store._setTokenSnapshotForTesting(claudeSnapshot, provider: .claude)
        fixture.store.tokenErrors[.codex] = "Profile A scan failed"
        fixture.store.lastTokenFetchAt[.codex] = Date()
        fixture.store.lastTokenFetchScope[.codex] = fixture.store.tokenSnapshotScopeSignature(for: .codex)
        fixture.store.lastCodexAccountScopedRefreshGuard = fixture.store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)

        fixture.settings.selectDisplayedCodexVisibleAccount(fixture.secondAccount)
        let didInvalidate = fixture.store.prepareCodexAccountScopedRefreshIfNeeded()

        #expect(didInvalidate)
        #expect(fixture.store.tokenSnapshots[.codex] == nil)
        #expect(fixture.store.tokenSnapshotPublications[.codex] == nil)
        #expect(fixture.store.tokenError(for: .codex) == nil)
        #expect(fixture.store.tokenLastAttemptAt(for: .codex) == nil)
        #expect(fixture.store.lastTokenFetchScope[.codex] == nil)
        #expect(fixture.store.tokenSnapshot(for: .claude) == claudeSnapshot)
        #expect(fixture.store.tokenSnapshotForCurrentProviderConfig(for: .claude)?.snapshot == claudeSnapshot)
    }

    @Test
    @MainActor
    func `profile home cost dashboard stays empty during scan and then publishes selected profile`() async throws {
        let fixture = try Self.makeProfileHomeCostFixture(suite: "CodexProfileHomeAccountTests-cost-scan")
        defer { fixture.cleanup() }

        let profileASnapshot = Self.costSnapshot(cost: 12, tokens: 1200, model: "fictional-profile-a")
        let profileBSnapshot = Self.costSnapshot(cost: 34, tokens: 3400, model: "fictional-profile-b")
        fixture.store._setTokenSnapshotForTesting(profileASnapshot, provider: .codex)
        fixture.store.lastCodexAccountScopedRefreshGuard = fixture.store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)
        let gate = CodexProfileHomeCostScanGate()
        fixture.store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, homePath, _ in
            #expect(provider == .codex)
            #expect(homePath == fixture.secondHome.path)
            return await gate.load()
        }

        fixture.settings.selectDisplayedCodexVisibleAccount(fixture.secondAccount)
        fixture.store.prepareCodexAccountScopedRefreshIfNeeded()
        let refresh = Task { @MainActor in
            await fixture.store.refreshTokenUsageNow(for: .codex, force: true)
        }
        await gate.waitUntilStarted()

        let loadingModel = ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_menuCardModel(for: .codex)
        #expect(fixture.store.isTokenRefreshInFlight(for: .codex))
        #expect(loadingModel.tokenUsage == nil)
        #expect(loadingModel.inlineUsageDashboard == nil)

        await gate.complete(with: profileBSnapshot)
        await refresh.value

        let completedModel = ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_menuCardModel(for: .codex)
        #expect(fixture.store.tokenSnapshot(for: .codex) == profileBSnapshot)
        #expect(completedModel.tokenUsage?.sessionLine.contains("$34") == true)
        #expect(completedModel.tokenUsage?.sessionLine.contains("$12") == false)
        #expect(completedModel.inlineUsageDashboard?.points.map(\.value) == [34])
        #expect(completedModel.inlineUsageDashboard?.detailLines
            .contains { $0.contains("fictional-profile-b") } == true)
        #expect(completedModel.inlineUsageDashboard?.detailLines
            .contains { $0.contains("fictional-profile-a") } == false)
    }

    @Test
    @MainActor
    func `ambient codex ledger remains visible when profile home selection changes`() throws {
        let fixture = try Self.makeProfileHomeCostFixture(
            suite: "CodexProfileHomeAccountTests-ambient-ledger",
            localLedgerEnabled: true)
        defer { fixture.cleanup() }

        let ambientSnapshot = Self.costSnapshot(cost: 56, tokens: 5600, model: "fictional-ambient")
        fixture.store._setTokenSnapshotForTesting(ambientSnapshot, provider: .codex)
        fixture.store.lastCodexAccountScopedRefreshGuard = fixture.store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)

        fixture.settings.selectDisplayedCodexVisibleAccount(fixture.secondAccount)
        fixture.store.prepareCodexAccountScopedRefreshIfNeeded()

        let model = ProvidersPane(settings: fixture.settings, store: fixture.store)
            ._test_menuCardModel(for: .codex)
        #expect(fixture.store.tokenSnapshot(for: .codex) == ambientSnapshot)
        #expect(model.tokenUsage?.sessionLine.contains("$56") == true)
        #expect(model.inlineUsageDashboard?.points.map(\.value) == [56])
    }

    @Test
    @MainActor
    func `removed profile home falls back without routing stale path`() throws {
        let suite = "CodexProfileHomeAccountTests-stale-routing"
        let settings = try Self.makeSettings(suite: suite)
        let missingLiveHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let removedProfileHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": missingLiveHome.path]
        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = []
            entry.codexActiveSource = .profileHome(path: removedProfileHome.path)
        }
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: missingLiveHome)
            try? FileManager.default.removeItem(at: removedProfileHome)
        }

        let environment = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": "/tmp/ambient-codex"],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(settings.codexResolvedActiveSource == .liveSystem)
        #expect(environment["CODEX_HOME"] == "/tmp/ambient-codex")
        let staleOverrideEnvironment = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": "/tmp/ambient-codex"],
            provider: .codex,
            settings: settings,
            tokenOverride: nil,
            codexActiveSourceOverride: .profileHome(path: removedProfileHome.path))
        #expect(staleOverrideEnvironment["CODEX_HOME"] == "/tmp/ambient-codex")
        #expect(settings.persistResolvedCodexActiveSourceCorrectionIfNeeded())
        #expect(settings.codexActiveSource == .liveSystem)
    }

    @Test
    @MainActor
    func `external config removal immediately invalidates profile routing caches`() throws {
        let suite = "CodexProfileHomeAccountTests-external-removal"
        let settings = try Self.makeSettings(suite: suite)
        let missingLiveHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let profileHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: profileHome,
            email: "profile-cache@example.com",
            plan: "pro")
        let previousInterval = SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": missingLiveHome.path]
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = previousInterval
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: missingLiveHome)
            try? FileManager.default.removeItem(at: profileHome)
        }

        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = [profileHome.path]
            entry.codexActiveSource = .profileHome(path: profileHome.path)
        }
        _ = settings.codexAccountReconciliationSnapshot
        #expect(settings.cachedCodexAccountReconciliationSnapshot != nil)
        #expect(settings.cachedCodexAccountMenuProjection != nil)

        var externalProviderConfig = ProviderConfig(id: .codex)
        externalProviderConfig.codexActiveSource = .profileHome(path: profileHome.path)
        externalProviderConfig.codexProfileHomePaths = []
        settings.applyExternalConfig(
            CodexBarConfig(providers: [externalProviderConfig]),
            reason: "profile-removed")

        #expect(settings.cachedCodexAccountReconciliationSnapshot == nil)
        #expect(settings.cachedCodexAccountMenuProjection == nil)
        let environment = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": "/tmp/ambient-codex"],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)
        #expect(settings.codexResolvedActiveSource == .liveSystem)
        #expect(environment["CODEX_HOME"] == "/tmp/ambient-codex")
    }

    @Test
    @MainActor
    func `relative profile homes are ignored by app routing`() throws {
        let settings = try Self.makeSettings(suite: "CodexProfileHomeAccountTests-relative")
        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = ["relative-codex-home", "~someone/.codex"]
            entry.codexActiveSource = .profileHome(path: "relative-codex-home")
        }

        #expect(CodexHomeScope.normalizedHomePath("relative-codex-home") == nil)
        #expect(CodexHomeScope.normalizedHomePath("~someone/.codex") == nil)
        #expect(settings.codexProfileHomePaths.isEmpty)
        let environment = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": "/tmp/ambient-codex"],
            provider: .codex,
            settings: settings,
            tokenOverride: nil,
            codexActiveSourceOverride: .profileHome(path: "relative-codex-home"))
        #expect(environment["CODEX_HOME"] == "/tmp/ambient-codex")
    }

    @Test
    @MainActor
    func `unreadable configured profile home remains selected and routed`() throws {
        let suite = "CodexProfileHomeAccountTests-unreadable-routing"
        let settings = try Self.makeSettings(suite: suite)
        let missingLiveHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let unreadableProfileHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": missingLiveHome.path]
        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = [unreadableProfileHome.path]
            entry.codexActiveSource = .profileHome(path: unreadableProfileHome.path)
        }
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: missingLiveHome)
            try? FileManager.default.removeItem(at: unreadableProfileHome)
        }

        let normalizedProfilePath = try #require(CodexHomeScope.normalizedHomePath(unreadableProfileHome.path))
        let environment = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": "/tmp/ambient-codex"],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(settings.codexResolvedActiveSource == .profileHome(path: normalizedProfilePath))
        #expect(settings.codexAccountReconciliationSnapshot.profileHomeAccounts.isEmpty)
        #expect(environment["CODEX_HOME"] == normalizedProfilePath)
        #expect(!settings.persistResolvedCodexActiveSourceCorrectionIfNeeded())
        #expect(settings.codexActiveSource == .profileHome(path: normalizedProfilePath))
    }

    @Test
    @MainActor
    func `profile without verified email refuses open A I cookie import`() async throws {
        let suite = "CodexProfileHomeAccountTests-missing-web-email"
        let settings = try Self.makeSettings(suite: suite)
        let missingLiveHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let unreadableProfileHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": missingLiveHome.path]
        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = [unreadableProfileHome.path]
            entry.codexActiveSource = .profileHome(path: unreadableProfileHome.path)
        }
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: missingLiveHome)
            try? FileManager.default.removeItem(at: unreadableProfileHome)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": missingLiveHome.path]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        var importAttempts = 0
        store._test_openAIDashboardCookieImportOverride = { _, _, _, _, _ in
            importAttempts += 1
            return OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "test",
                cookieCount: 1,
                signedInEmail: "other@example.com",
                matchesCodexEmail: false)
        }

        let imported = await store.importOpenAIDashboardCookiesIfNeeded(targetEmail: nil, force: true)

        #expect(imported == nil)
        #expect(importAttempts == 0)
        #expect(store.openAIDashboardRequiresLogin)
        #expect(store.openAIDashboardCookieImportStatus?.contains("no verified account email") == true)
    }

    @Test
    @MainActor
    func `profile home matching live home resolves to visible live account`() throws {
        let suite = "CodexProfileHomeAccountTests-live-duplicate"
        let settings = try Self.makeSettings(suite: suite)
        let liveHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let liveAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: liveHome.path,
            observedAt: Date())
        settings._test_liveSystemCodexAccount = liveAccount
        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = [liveHome.path]
            entry.codexActiveSource = .profileHome(path: liveHome.path)
        }
        defer {
            settings._test_liveSystemCodexAccount = nil
        }

        let projection = settings.codexVisibleAccountProjection

        #expect(settings.codexResolvedActiveSource == .liveSystem)
        #expect(projection.visibleAccounts.map(\.email) == ["live@example.com"])
        #expect(projection.activeVisibleAccountID == "live@example.com")
        #expect(settings.persistResolvedCodexActiveSourceCorrectionIfNeeded())
        #expect(settings.codexActiveSource == .liveSystem)
    }

    @Test
    @MainActor
    func `profile home matching managed home resolves to visible managed account`() throws {
        let suite = "CodexProfileHomeAccountTests-managed-duplicate"
        let settings = try Self.makeSettings(suite: suite)
        let managedHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = [managedHome.path]
            entry.codexActiveSource = .profileHome(path: managedHome.path)
        }
        defer {
            settings._test_activeManagedCodexAccount = nil
        }

        let projection = settings.codexVisibleAccountProjection

        #expect(settings.codexResolvedActiveSource == .managedAccount(id: managedAccount.id))
        #expect(projection.visibleAccounts.map(\.email) == ["managed@example.com"])
        #expect(projection.activeVisibleAccountID == "managed@example.com")
        #expect(settings.persistResolvedCodexActiveSourceCorrectionIfNeeded())
        #expect(settings.codexActiveSource == .managedAccount(id: managedAccount.id))
    }

    @MainActor
    private struct ProfileHomeCostFixture {
        let settings: SettingsStore
        let store: UsageStore
        let root: URL
        let secondHome: URL
        let secondAccount: CodexVisibleAccount

        func cleanup() {
            self.store._test_tokenUsageSnapshotLoaderOverride = nil
            self.settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: self.root)
        }
    }

    @MainActor
    private static func makeProfileHomeCostFixture(
        suite: String,
        localLedgerEnabled: Bool = false) throws -> ProfileHomeCostFixture
    {
        let settings = try Self.makeSettings(suite: suite)
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        settings.codexLocalSessionCostLedgerEnabled = localLedgerEnabled
        let root = CodexCredentialFixtures.root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstHome = root.appendingPathComponent("profile-a", isDirectory: true)
        let secondHome = root.appendingPathComponent("profile-b", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: firstHome,
            email: "profile-a@example.com",
            plan: "pro",
            accountID: "acct-profile-a")
        try Self.writeCodexAuthFile(
            homeURL: secondHome,
            email: "profile-b@example.com",
            plan: "pro",
            accountID: "acct-profile-b")
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent("missing-live-home", isDirectory: true).path,
        ]
        settings._test_codexReconciliationEnvironment = environment
        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = [firstHome.path, secondHome.path]
            entry.codexActiveSource = .profileHome(path: firstHome.path)
        }
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let secondAccount = try #require(settings.codexVisibleAccounts.first {
            $0.email == "profile-b@example.com"
        })
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: root.path, cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        return ProfileHomeCostFixture(
            settings: settings,
            store: store,
            root: root,
            secondHome: secondHome,
            secondAccount: secondAccount)
    }

    private static func costSnapshot(cost: Double, tokens: Int, model: String) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            daily: [CostUsageDailyReport.Entry(
                date: "2026-08-21",
                inputTokens: tokens / 2,
                outputTokens: tokens / 2,
                totalTokens: tokens,
                costUSD: cost,
                modelsUsed: [model],
                modelBreakdowns: [CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: cost,
                    totalTokens: tokens)])],
            updatedAt: Date())
    }

    private static func writeCodexAuthFile(
        homeURL: URL,
        email: String,
        plan: String,
        accountID: String? = nil) throws
    {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        var tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, plan: plan, accountID: accountID),
        ]
        if let accountID {
            tokens["account_id"] = accountID
        }
        let auth = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String, accountID: String? = nil) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        var payloadObject: [String: Any] = [
            "email": email,
            "chatgpt_plan_type": plan,
        ]
        if let accountID {
            payloadObject["https://api.openai.com/auth"] = [
                "chatgpt_account_id": accountID,
            ]
        }
        let payload = (try? JSONSerialization.data(withJSONObject: payloadObject)) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}

private actor CodexProfileHomeCostScanGate {
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var snapshotContinuation: CheckedContinuation<CostUsageTokenSnapshot, Never>?

    func load() async -> CostUsageTokenSnapshot {
        self.started = true
        self.startedContinuation?.resume()
        self.startedContinuation = nil
        return await withCheckedContinuation { continuation in
            self.snapshotContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.startedContinuation = continuation
        }
    }

    func complete(with snapshot: CostUsageTokenSnapshot) {
        self.snapshotContinuation?.resume(returning: snapshot)
        self.snapshotContinuation = nil
    }
}
