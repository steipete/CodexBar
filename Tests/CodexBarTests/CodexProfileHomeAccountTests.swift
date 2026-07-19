import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
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
        let missingLiveHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let profileHome = FileManager.default.temporaryDirectory.appendingPathComponent(
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
        let profileHome = FileManager.default.temporaryDirectory.appendingPathComponent(
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
    func `removed profile home falls back without routing stale path`() throws {
        let suite = "CodexProfileHomeAccountTests-stale-routing"
        let settings = try Self.makeSettings(suite: suite)
        let missingLiveHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let removedProfileHome = FileManager.default.temporaryDirectory.appendingPathComponent(
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
        let missingLiveHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let profileHome = FileManager.default.temporaryDirectory.appendingPathComponent(
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

        settings.applyExternalConfig(
            CodexBarConfig(providers: [
                ProviderConfig(
                    id: .codex,
                    codexActiveSource: .profileHome(path: profileHome.path),
                    codexProfileHomePaths: []),
            ]),
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
        let missingLiveHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let unreadableProfileHome = FileManager.default.temporaryDirectory.appendingPathComponent(
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
        let missingLiveHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let unreadableProfileHome = FileManager.default.temporaryDirectory.appendingPathComponent(
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
        let liveHome = FileManager.default.temporaryDirectory.appendingPathComponent(
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
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
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
