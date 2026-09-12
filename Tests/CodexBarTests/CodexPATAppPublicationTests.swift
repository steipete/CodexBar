import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    @Test
    func `ambient PAT publishes while a different managed Codex account is active`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexPATAppPublicationTests-managed-active")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings.codexUsageDataSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "live-oauth@example.com")

        let managedID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-999999999999"))
        let managedHome = CodexCredentialFixtures.root
            .appendingPathComponent("codex-pat-managed-\(UUID().uuidString)", isDirectory: true)
        let managedAccount = ManagedCodexAccount(
            id: managedID,
            email: "managed@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings.codexActiveSource = .managedAccount(id: managedID)

        let ambientRoot = CodexCredentialFixtures.root
            .appendingPathComponent("codex-pat-ambient-\(UUID().uuidString)", isDirectory: true)
        let ambientCodexHome = ambientRoot.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ambientCodexHome, withIntermediateDirectories: true)
        try Data(#"{"personal_access_token":"at-test-token"}"#.utf8)
            .write(to: ambientCodexHome.appendingPathComponent("auth.json"))
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: managedStoreURL)
            try? FileManager.default.removeItem(at: managedHome)
            try? FileManager.default.removeItem(at: ambientRoot)
        }

        let environment = [
            "HOME": ambientRoot.path,
            "CODEX_HOME": ambientCodexHome.path,
            "XDG_CONFIG_HOME": ambientRoot.appendingPathComponent(".config", isDirectory: true)
                .path,
        ]
        let store = self.makeUsageStore(settings: settings, environmentBase: environment)
        store._test_codexResetCreditsFetcherOverride = { _ in nil }
        let baseSpec = try #require(store.providerSpecs[.codex])
        let patSnapshot = self.codexSnapshot(email: "pat@example.com", usedPercent: 68)
        let strategy = TestCodexFetchStrategy(
            loader: { patSnapshot },
            credits: nil,
            id: "codex.pat",
            kind: .apiToken,
            sourceLabel: "pat")
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) { _ in
            [strategy]
        }

        #expect(store.shouldUseAmbientCodexPATForUsage())
        #expect(!store.shouldFetchAllCodexVisibleAccounts())

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "pat@example.com")
        #expect(store.snapshots[.codex]?.primary?.usedPercent == 68)
        #expect(store.lastSourceLabels[.codex] == "pat")
        #expect(store.lastCodexUsagePublicationGuard?.source == .liveSystem)
    }

    @Test
    func `profile-only PAT skips stacked fan-out and publishes`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexPATAppPublicationTests-profile-pat")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings.codexUsageDataSource = .auto
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "live-oauth@example.com")

        let profileHome = CodexCredentialFixtures.root
            .appendingPathComponent("codex-pat-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profileHome, withIntermediateDirectories: true)
        try Data(#"{"personal_access_token":"at-profile-only"}"#.utf8)
            .write(to: profileHome.appendingPathComponent("auth.json"))
        settings.updateProviderConfig(provider: .codex) { entry in
            entry.codexProfileHomePaths = [profileHome.path]
            entry.codexActiveSource = .profileHome(path: profileHome.path)
        }

        let ambientRoot = CodexCredentialFixtures.root
            .appendingPathComponent(
                "codex-pat-ambient-empty-\(UUID().uuidString)", isDirectory: true)
        let ambientCodexHome = ambientRoot.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ambientCodexHome, withIntermediateDirectories: true)
        defer {
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: profileHome)
            try? FileManager.default.removeItem(at: ambientRoot)
        }

        let environment = [
            "HOME": ambientRoot.path,
            "CODEX_HOME": ambientCodexHome.path,
            "XDG_CONFIG_HOME": ambientRoot.appendingPathComponent(".config", isDirectory: true)
                .path,
        ]
        let store = self.makeUsageStore(settings: settings, environmentBase: environment)
        store._test_codexResetCreditsFetcherOverride = { _ in nil }
        let baseSpec = try #require(store.providerSpecs[.codex])
        let patSnapshot = self.codexSnapshot(email: "pat-profile@example.com", usedPercent: 41)
        let strategy = TestCodexFetchStrategy(
            loader: { patSnapshot },
            credits: nil,
            id: "codex.pat",
            kind: .apiToken,
            sourceLabel: "pat")
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) { _ in
            [strategy]
        }

        #expect((try? CodexOAuthCredentialsStore.loadPAT(env: store.environmentBase)) == nil)
        #expect(store.shouldUseAmbientCodexPATForUsage())
        #expect(!store.shouldFetchAllCodexVisibleAccounts())

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "pat-profile@example.com")
        #expect(store.snapshots[.codex]?.primary?.usedPercent == 41)
        #expect(store.lastSourceLabels[.codex] == "pat")
    }
}
