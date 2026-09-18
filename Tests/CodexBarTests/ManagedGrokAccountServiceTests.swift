import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct ManagedGrokAccountServiceTests {
    @Test
    func `add account stores email and home under the managed root`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryManagedGrokAccountStore(
            snapshot: ManagedGrokAccountSet(version: 1, accounts: []))
        let service = ManagedGrokAccountService(
            store: store,
            homeFactory: TestManagedGrokHomeFactory(root: root),
            loginRunner: StubManagedGrokLoginRunner.success,
            identityReader: StubManagedGrokIdentityReader(email: "grok-a@example.com", userID: "user-a"))

        let account = try await service.authenticateManagedAccount()
        #expect(account.email == "grok-a@example.com")
        #expect(account.userID == "user-a")
        #expect(account.managedHomePath.hasPrefix(root.standardizedFileURL.path + "/"))
        #expect(store.snapshot.accounts.count == 1)
    }

    @Test
    func `same email upserts instead of duplicating`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryManagedGrokAccountStore(
            snapshot: ManagedGrokAccountSet(version: 1, accounts: []))
        let service = ManagedGrokAccountService(
            store: store,
            homeFactory: TestManagedGrokHomeFactory(root: root),
            loginRunner: StubManagedGrokLoginRunner.success,
            identityReader: StubManagedGrokIdentityReader(email: "grok-a@example.com", userID: "user-a"))

        let first = try await service.authenticateManagedAccount()
        let second = try await service.authenticateManagedAccount()
        #expect(first.id == second.id)
        #expect(store.snapshot.accounts.count == 1)
    }

    @Test
    func `missing email fails closed and deletes the new home`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = InMemoryManagedGrokAccountStore(
            snapshot: ManagedGrokAccountSet(version: 1, accounts: []))
        let service = ManagedGrokAccountService(
            store: store,
            homeFactory: TestManagedGrokHomeFactory(root: root),
            loginRunner: StubManagedGrokLoginRunner.success,
            identityReader: StubManagedGrokIdentityReader(email: nil, userID: "user-a"))

        await #expect(throws: ManagedGrokAccountServiceError.missingEmail) {
            _ = try await service.authenticateManagedAccount()
        }
        #expect(store.snapshot.accounts.isEmpty)
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(leftover.isEmpty)
    }
}

struct GrokVisibleAccountProjectionTests {
    @Test
    func `live plus managed accounts expose stacked identities`() {
        let managedID = UUID()
        let projection = GrokVisibleAccountProjectionFactory.make(
            liveEmail: "system@example.com",
            liveHomePath: "/tmp/live-grok",
            managedAccounts: [
                ManagedGrokAccount(
                    id: managedID,
                    email: "second@example.com",
                    managedHomePath: "/tmp/managed-grok",
                    createdAt: 1,
                    updatedAt: 1,
                    lastAuthenticatedAt: 1),
            ],
            persistedSource: .managedAccount(id: managedID),
            hasUnreadableAddedAccountStore: false)

        #expect(projection.visibleAccounts.count == 2)
        #expect(projection.liveVisibleAccountID == GrokVisibleAccount.liveAccountID)
        #expect(projection.activeVisibleAccountID == managedID.uuidString)
        #expect(projection.visibleAccounts[0].isLive)
        #expect(projection.visibleAccounts[1].canRemove)
    }

    @Test
    func `missing managed selection falls back to live`() {
        let projection = GrokVisibleAccountProjectionFactory.make(
            liveEmail: "system@example.com",
            liveHomePath: "/tmp/live-grok",
            managedAccounts: [],
            persistedSource: .managedAccount(id: UUID()),
            hasUnreadableAddedAccountStore: false)
        #expect(projection.activeVisibleAccountID == GrokVisibleAccount.liveAccountID)
        #expect(GrokActiveSourceResolver.resolve(
            persistedSource: .managedAccount(id: UUID()),
            liveAccount: projection.visibleAccounts.first,
            managedAccounts: []) == .liveSystem)
    }
}

struct GrokHomeScopeTests {
    @Test
    func `scoped environment sets GROK_HOME and strips pasted oauth tokens`() {
        let env = GrokHomeScope.scopedEnvironment(
            base: [
                "PATH": "/usr/bin",
                GrokSettingsReader.oauthTokenEnvironmentKey: "pasted-token",
            ],
            grokHome: "/tmp/grok-b")
        #expect(env["GROK_HOME"] == "/tmp/grok-b")
        #expect(env[GrokSettingsReader.oauthTokenEnvironmentKey] == nil)
        #expect(env["PATH"] == "/usr/bin")
    }
}

private struct TestManagedGrokHomeFactory: ManagedGrokHomeProducing {
    let root: URL

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        let rootPath = self.root.standardizedFileURL.path + "/"
        let targetPath = url.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath) else {
            throw ManagedGrokAccountServiceError.unsafeManagedHome(url.path)
        }
    }
}

private struct StubManagedGrokLoginRunner: ManagedGrokLoginRunning {
    static let success = StubManagedGrokLoginRunner()

    func run(
        homePath _: String,
        timeout _: TimeInterval,
        onProgress _: (@Sendable (String) -> Void)?) async -> CLILoginRunner.Result
    {
        CLILoginRunner.Result(outcome: .success, output: "ok")
    }
}

private struct StubManagedGrokIdentityReader: ManagedGrokIdentityReading {
    let email: String?
    let userID: String?

    func loadAccountIdentity(homePath _: String) throws -> GrokCredentials {
        GrokCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            scope: "https://auth.x.ai::test",
            authMode: "oidc",
            userId: self.userID,
            email: self.email,
            firstName: nil,
            lastName: nil,
            teamId: nil,
            oidcIssuer: nil,
            oidcClientId: nil,
            expiresAt: nil,
            createTime: nil)
    }
}

private final class InMemoryManagedGrokAccountStore: ManagedGrokAccountStoring, @unchecked Sendable {
    var snapshot: ManagedGrokAccountSet

    init(snapshot: ManagedGrokAccountSet) {
        self.snapshot = snapshot
    }

    func loadAccounts() throws -> ManagedGrokAccountSet {
        self.snapshot
    }

    func storeAccounts(_ accounts: ManagedGrokAccountSet) throws {
        self.snapshot = accounts
    }
}

struct GrokAccountMenuDisplayTests {
    @Test
    func `segmented layout shows a switcher instead of stacked cards`() {
        let display = GrokAccountMenuDisplay(
            accounts: [Self.account("one@example.com"), Self.account("two@example.com")],
            snapshots: [],
            activeVisibleAccountID: "one@example.com",
            layout: .segmented)
        #expect(display.showSwitcher)
        #expect(display.showAll == false)
    }

    @Test
    func `stacked layout shows all cards`() {
        let display = GrokAccountMenuDisplay(
            accounts: [Self.account("one@example.com"), Self.account("two@example.com")],
            snapshots: [],
            activeVisibleAccountID: "one@example.com",
            layout: .stacked)
        #expect(display.showAll)
        #expect(display.showSwitcher == false)
    }

    private static func account(_ email: String) -> GrokVisibleAccount {
        GrokVisibleAccount(
            id: email,
            email: email,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            managedHomePath: nil,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
    }
}

struct GrokManagedAccountRoutingTests {
    @Test
    @MainActor
    func `live routing preserves ambient GROK_HOME and oauth token`() {
        let settings = testSettingsStore(suiteName: "GrokRouting-live")
        let env = ProviderRegistry.makeEnvironment(
            base: [
                "GROK_HOME": "/tmp/ambient-grok",
                GrokSettingsReader.oauthTokenEnvironmentKey: "ambient-token",
            ],
            provider: .grok,
            settings: settings,
            tokenOverride: nil)
        #expect(env["GROK_HOME"] == "/tmp/ambient-grok")
        #expect(env[GrokSettingsReader.oauthTokenEnvironmentKey] == "ambient-token")
    }

    @Test
    @MainActor
    func `managed routing scopes home and strips ambient oauth token`() throws {
        let settings = testSettingsStore(suiteName: "GrokRouting-managed")
        let accountID = UUID()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "grok-managed-\(accountID.uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = FileManagedGrokAccountStore()
        let previous = (try? store.loadAccounts()) ?? ManagedGrokAccountSet(version: 1, accounts: [])
        defer { try? store.storeAccounts(previous) }
        try store.storeAccounts(
            ManagedGrokAccountSet(
                version: 1,
                accounts: [
                    ManagedGrokAccount(
                        id: accountID,
                        email: "managed@example.com",
                        managedHomePath: home.path,
                        createdAt: 1,
                        updatedAt: 1,
                        lastAuthenticatedAt: 1),
                ]))
        settings.grokActiveSource = .managedAccount(id: accountID)

        let env = ProviderRegistry.makeEnvironment(
            base: [
                "GROK_HOME": "/tmp/ambient-grok",
                GrokSettingsReader.oauthTokenEnvironmentKey: "ambient-token",
            ],
            provider: .grok,
            settings: settings,
            tokenOverride: nil)
        #expect(env["GROK_HOME"] == GrokHomeScope.normalizedHomePath(home.path))
        #expect(env[GrokSettingsReader.oauthTokenEnvironmentKey] == nil)
    }

    @Test
    @MainActor
    func `live override keeps ambient credentials even when a managed account is selected`() {
        let settings = testSettingsStore(suiteName: "GrokRouting-live-override")
        settings.grokActiveSource = .managedAccount(id: UUID())
        let env = ProviderRegistry.makeEnvironment(
            base: [
                "GROK_HOME": "/tmp/ambient-grok",
                GrokSettingsReader.oauthTokenEnvironmentKey: "ambient-token",
            ],
            provider: .grok,
            settings: settings,
            tokenOverride: nil,
            grokActiveSourceOverride: .liveSystem)
        #expect(env["GROK_HOME"] == "/tmp/ambient-grok")
        #expect(env[GrokSettingsReader.oauthTokenEnvironmentKey] == "ambient-token")
    }

    @Test
    func `fetched identity is compared before any relabel`() {
        #expect(GrokFetchedAccountIdentity.matches("Managed@Example.com", storedEmail: "managed@example.com"))
        #expect(GrokFetchedAccountIdentity.matches("other@example.com", storedEmail: "managed@example.com") == false)
        #expect(GrokFetchedAccountIdentity.matches(nil, storedEmail: "managed@example.com"))
        #expect(GrokFetchedAccountIdentity.matches("  ", storedEmail: "managed@example.com"))
    }
}

struct GrokAccountSwitcherPrivacyTests {
    @Test
    @MainActor
    func `hide personal info does not put email in tooltips`() {
        let accounts = [
            GrokAccountMenuDisplayTestsAccount.make("alpha@example.com"),
            GrokAccountMenuDisplayTestsAccount.make("beta@example.com"),
        ]
        let view = GrokAccountSwitcherView(
            accounts: accounts,
            selectedAccountID: accounts[0].id,
            width: 320,
            hidePersonalInfo: true,
            onSelect: { _ in })
        let tooltips = view._test_buttonToolTips()
        #expect(!tooltips.isEmpty)
        #expect(!tooltips.contains { $0.contains("@") })
    }
}

private enum GrokAccountMenuDisplayTestsAccount {
    static func make(_ email: String) -> GrokVisibleAccount {
        GrokVisibleAccount(
            id: email,
            email: email,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            managedHomePath: nil,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
    }
}
