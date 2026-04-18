import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ManagedCodexAccountServiceTests {
    @Test
    func `upsert preserves uuid for matching canonical email`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("managed.json", isDirectory: false)
        let store = FileManagedCodexAccountStore(fileURL: fileURL, fileManager: .default)
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(identity: .providerAccount(id: "account-live"), email: "user@example.com", plan: "Pro"),
                .init(identity: .providerAccount(id: "account-live"), email: "user@example.com", plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        let first = try await service.authenticateManagedAccount()
        let second = try await service.authenticateManagedAccount()
        let snapshot = try store.loadAccounts()

        #expect(first.id == second.id)
        #expect(second.email == "user@example.com")
        #expect(second.providerAccountID == "account-live")
        #expect(snapshot.accounts.count == 1)
        #expect(second.managedHomePath.hasPrefix(root.standardizedFileURL.path + "/"))
    }

    @Test
    func `new authentication appends managed account without implicit selection side effect`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let firstAccount = ManagedCodexAccount(
            id: firstID,
            email: "first@example.com",
            managedHomePath: root.appendingPathComponent("accounts/first", isDirectory: true).path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let store = InMemoryManagedCodexAccountStore(
            accounts: ManagedCodexAccountSet(
                version: 1,
                accounts: [firstAccount]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(identity: .providerAccount(id: "account-second"), email: "second@example.com", plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        let authenticated = try await service.authenticateManagedAccount()

        #expect(store.snapshot.accounts.count == 2)
        #expect(authenticated.email == "second@example.com")
        #expect(authenticated.providerAccountID == "account-second")
    }

    @Test
    func `same email provider backed workspaces coexist across sequential add account flows`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InMemoryManagedCodexAccountStore(
            accounts: ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: []))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(identity: .providerAccount(id: "workspace-personal"), email: "alice@example.com", plan: "Pro"),
                .init(identity: .providerAccount(id: "workspace-team"), email: "alice@example.com", plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver(identities: [
                "workspace-personal": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "workspace-personal",
                    workspaceLabel: "Personal"),
                "workspace-team": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "workspace-team",
                    workspaceLabel: "Team"),
            ]))

        let personal = try await service.authenticateManagedAccount()
        let team = try await service.authenticateManagedAccount()

        let storedPersonal = try #require(
            store.snapshot.account(email: "alice@example.com", providerAccountID: "workspace-personal"))
        let storedTeam = try #require(
            store.snapshot.account(email: "alice@example.com", providerAccountID: "workspace-team"))
        #expect(store.snapshot.accounts.count == 2)
        #expect(personal.id == storedPersonal.id)
        #expect(team.id == storedTeam.id)
        #expect(personal.id != team.id)
        #expect(storedPersonal.providerAccountID == "workspace-personal")
        #expect(storedPersonal.workspaceLabel == "Personal")
        #expect(storedTeam.providerAccountID == "workspace-team")
        #expect(storedTeam.workspaceLabel == "Team")
        #expect(storedPersonal.managedHomePath != storedTeam.managedHomePath)
        #expect(FileManager.default.fileExists(atPath: storedPersonal.managedHomePath))
        #expect(FileManager.default.fileExists(atPath: storedTeam.managedHomePath))
    }

    @Test
    func `reauth keeps previous home when store write fails`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let existingHome = root.appendingPathComponent("accounts/existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existingAccountID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let existingAccount = ManagedCodexAccount(
            id: existingAccountID,
            email: "user@example.com",
            managedHomePath: existingHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let store = FailingManagedCodexAccountStore(
            accounts: ManagedCodexAccountSet(
                version: 1,
                accounts: [existingAccount]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(identity: .providerAccount(id: "account-live"), email: "user@example.com", plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        await #expect(throws: TestManagedCodexAccountStoreError.writeFailed) {
            try await service.authenticateManagedAccount()
        }

        let newHome = root.appendingPathComponent("accounts/account-1", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: existingHome.path))
        #expect(FileManager.default.fileExists(atPath: newHome.path) == false)
        #expect(store.snapshot.accounts.count == 1)
        #expect(store.snapshot.accounts.first?.managedHomePath == existingHome.path)
    }

    @Test
    func `reauth reconciles by provider account id before existing account id`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let alphaHome = root.appendingPathComponent("accounts/alpha", isDirectory: true)
        let betaHome = root.appendingPathComponent("accounts/beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let alphaID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let betaID = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-222222222222"))
        let alphaAccount = ManagedCodexAccount(
            id: alphaID,
            email: "shared@example.com",
            providerAccountID: "account-alpha",
            managedHomePath: alphaHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let betaAccount = ManagedCodexAccount(
            id: betaID,
            email: "shared@example.com",
            providerAccountID: "account-beta",
            managedHomePath: betaHome.path,
            createdAt: 2,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let store = InMemoryManagedCodexAccountStore(
            accounts: ManagedCodexAccountSet(
                version: 1,
                accounts: [alphaAccount, betaAccount]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(identity: .providerAccount(id: "account-beta"), email: "SHARED@example.com", plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        let account = try await service.authenticateManagedAccount(existingAccountID: alphaAccount.id)

        let storedAlpha = try #require(store.snapshot.account(id: alphaAccount.id))
        let storedBeta = try #require(store.snapshot.account(id: betaAccount.id))
        #expect(account.id == betaAccount.id)
        #expect(store.snapshot.accounts.count == 2)
        #expect(storedAlpha.email == "shared@example.com")
        #expect(storedAlpha.providerAccountID == "account-alpha")
        #expect(storedAlpha.managedHomePath == alphaHome.path)
        #expect(storedBeta.email == "shared@example.com")
        #expect(storedBeta.providerAccountID == "account-beta")
        #expect(storedBeta.managedHomePath.hasPrefix(root.standardizedFileURL.path + "/"))
        #expect(storedBeta.managedHomePath != betaHome.path)
        #expect(FileManager.default.fileExists(atPath: alphaHome.path))
        #expect(FileManager.default.fileExists(atPath: betaHome.path) == false)
        #expect(FileManager.default.fileExists(atPath: storedBeta.managedHomePath))
    }

    @Test
    func `reauth to different account does not overwrite existing account id match`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let aliceHome = root.appendingPathComponent("accounts/alice", isDirectory: true)
        try FileManager.default.createDirectory(at: aliceHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let aliceID = try #require(UUID(uuidString: "12121212-3434-5656-7878-909090909090"))
        let aliceAccount = ManagedCodexAccount(
            id: aliceID,
            email: "alice@example.com",
            providerAccountID: "account-alice",
            managedHomePath: aliceHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let store = InMemoryManagedCodexAccountStore(accounts: ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [aliceAccount]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(identity: .providerAccount(id: "account-bob"), email: "bob@example.com", plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        let account = try await service.authenticateManagedAccount(existingAccountID: aliceID)

        let storedAlice = try #require(store.snapshot.account(id: aliceID))
        let storedBob = try #require(store.snapshot.account(email: "bob@example.com"))
        #expect(account.id != aliceID)
        #expect(account.id == storedBob.id)
        #expect(store.snapshot.accounts.count == 2)
        #expect(storedAlice.email == "alice@example.com")
        #expect(storedAlice.providerAccountID == "account-alice")
        #expect(storedAlice.managedHomePath == aliceHome.path)
        #expect(storedBob.email == "bob@example.com")
        #expect(storedBob.providerAccountID == "account-bob")
        #expect(storedBob.managedHomePath.hasPrefix(root.standardizedFileURL.path + "/"))
        #expect(storedBob.managedHomePath != aliceHome.path)
        #expect(FileManager.default.fileExists(atPath: aliceHome.path))
        #expect(FileManager.default.fileExists(atPath: storedBob.managedHomePath))
    }

    @Test
    func `reauth on same email different workspace does not overwrite selected workspace`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let personalHome = root.appendingPathComponent("accounts/personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personalHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let personalID = try #require(UUID(uuidString: "31313131-4242-5353-6464-757575757575"))
        let personalAccount = ManagedCodexAccount(
            id: personalID,
            email: "alice@example.com",
            providerAccountID: "workspace-personal",
            workspaceLabel: "Personal",
            workspaceAccountID: "workspace-personal",
            managedHomePath: personalHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let store = InMemoryManagedCodexAccountStore(accounts: ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [personalAccount]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(identity: .providerAccount(id: "workspace-team"), email: "alice@example.com", plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver(identities: [
                "workspace-team": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "workspace-team",
                    workspaceLabel: "Team"),
            ]))

        let account = try await service.authenticateManagedAccount(existingAccountID: personalID)

        let storedPersonal = try #require(store.snapshot.account(id: personalID))
        let storedTeam = try #require(
            store.snapshot.account(email: "alice@example.com", providerAccountID: "workspace-team"))
        #expect(account.id == storedTeam.id)
        #expect(account.id != personalID)
        #expect(store.snapshot.accounts.count == 2)
        #expect(storedPersonal.providerAccountID == "workspace-personal")
        #expect(storedPersonal.workspaceLabel == "Personal")
        #expect(storedPersonal.managedHomePath == personalHome.path)
        #expect(storedTeam.providerAccountID == "workspace-team")
        #expect(storedTeam.workspaceLabel == "Team")
        #expect(storedTeam.managedHomePath != personalHome.path)
        #expect(FileManager.default.fileExists(atPath: personalHome.path))
        #expect(FileManager.default.fileExists(atPath: storedTeam.managedHomePath))
    }

    @Test
    func `legacy row collapses onto provider backed row when provider id resolves elsewhere`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyHome = root.appendingPathComponent("accounts/legacy", isDirectory: true)
        let providerHome = root.appendingPathComponent("accounts/provider", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyID = try #require(UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444"))
        let providerID = try #require(UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444"))
        let legacyAccount = ManagedCodexAccount(
            id: legacyID,
            email: "shared@example.com",
            managedHomePath: legacyHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let providerAccount = ManagedCodexAccount(
            id: providerID,
            email: "shared@example.com",
            providerAccountID: "account-real",
            managedHomePath: providerHome.path,
            createdAt: 2,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let store = InMemoryManagedCodexAccountStore(accounts: ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [legacyAccount, providerAccount]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(identity: .providerAccount(id: "account-real"), email: "shared@example.com", plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        let account = try await service.authenticateManagedAccount(existingAccountID: legacyAccount.id)

        #expect(account.id == providerAccount.id)
        #expect(store.snapshot.accounts.count == 1)
        #expect(store.snapshot.accounts.first?.id == providerAccount.id)
        #expect(store.snapshot.accounts.first?.providerAccountID == "account-real")
        #expect(FileManager.default.fileExists(atPath: legacyHome.path) == false)
        #expect(FileManager.default.fileExists(atPath: providerHome.path) == false)
        #expect(FileManager.default.fileExists(atPath: account.managedHomePath))
    }

    @Test
    func `fresh provider login removes stale legacy row without explicit existing account id`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyHome = root.appendingPathComponent("accounts/legacy", isDirectory: true)
        let providerHome = root.appendingPathComponent("accounts/provider", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyID = try #require(UUID(uuidString: "CCCCCCCC-1111-2222-3333-444444444444"))
        let providerID = try #require(UUID(uuidString: "DDDDDDDD-1111-2222-3333-444444444444"))
        let legacyAccount = ManagedCodexAccount(
            id: legacyID,
            email: "shared@example.com",
            managedHomePath: legacyHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let providerAccount = ManagedCodexAccount(
            id: providerID,
            email: "shared@example.com",
            providerAccountID: "account-real",
            managedHomePath: providerHome.path,
            createdAt: 2,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let store = InMemoryManagedCodexAccountStore(accounts: ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [legacyAccount, providerAccount]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(identity: .providerAccount(id: "account-real"), email: "shared@example.com", plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        let account = try await service.authenticateManagedAccount()

        #expect(account.id == providerAccount.id)
        #expect(store.snapshot.accounts.count == 1)
        #expect(store.snapshot.accounts.first?.id == providerAccount.id)
        #expect(FileManager.default.fileExists(atPath: legacyHome.path) == false)
        #expect(FileManager.default.fileExists(atPath: providerHome.path) == false)
        #expect(FileManager.default.fileExists(atPath: account.managedHomePath))
    }

    @Test
    func `authentication persists workspace metadata and tolerates missing workspace label`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InMemoryManagedCodexAccountStore(
            accounts: ManagedCodexAccountSet(version: FileManagedCodexAccountStore.currentVersion, accounts: []))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(identity: .providerAccount(id: "account-live"), email: "user@example.com", plan: "Pro"),
                .init(identity: .providerAccount(id: "account-fallback"), email: "fallback@example.com", plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver(identities: [
                "account-live": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "account-live",
                    workspaceLabel: "Team Alpha"),
                "account-fallback": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "account-fallback",
                    workspaceLabel: nil),
            ]))

        let labeled = try await service.authenticateManagedAccount()
        let fallback = try await service.authenticateManagedAccount()

        #expect(labeled.providerAccountID == "account-live")
        #expect(labeled.workspaceAccountID == "account-live")
        #expect(labeled.workspaceLabel == "Team Alpha")
        #expect(fallback.providerAccountID == "account-fallback")
        #expect(fallback.workspaceAccountID == "account-fallback")
        #expect(fallback.workspaceLabel == nil)
    }

    @Test
    func `reauth preserves stored provider metadata when refresh cannot resolve account id`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let existingHome = root.appendingPathComponent("accounts/existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existingID = try #require(UUID(uuidString: "EEEEEEEE-1111-2222-3333-444444444444"))
        let existingAccount = ManagedCodexAccount(
            id: existingID,
            email: "user@example.com",
            providerAccountID: "account-live",
            workspaceLabel: "Team Alpha",
            workspaceAccountID: "account-live",
            managedHomePath: existingHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let store = InMemoryManagedCodexAccountStore(accounts: ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [existingAccount]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.accounts([
                .init(
                    identity: .emailOnly(normalizedEmail: "user@example.com"),
                    email: "user@example.com",
                    plan: "Pro"),
            ]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        let account = try await service.authenticateManagedAccount(existingAccountID: existingID)
        let stored = try #require(store.snapshot.account(id: existingID))

        #expect(account.id == existingID)
        #expect(account.providerAccountID == "account-live")
        #expect(account.workspaceAccountID == "account-live")
        #expect(account.workspaceLabel == "Team Alpha")
        #expect(stored.providerAccountID == "account-live")
        #expect(stored.workspaceAccountID == "account-live")
        #expect(stored.workspaceLabel == "Team Alpha")
        #expect(FileManager.default.fileExists(atPath: existingHome.path) == false)
        #expect(FileManager.default.fileExists(atPath: account.managedHomePath))
    }

    @Test
    func `auth failure cleanup uses managed root safety check`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outsideHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideHome)
        }

        let store = InMemoryManagedCodexAccountStore(
            accounts: ManagedCodexAccountSet(version: 1, accounts: []))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: UnsafeManagedCodexHomeFactory(root: root, homeURL: outsideHome),
            loginRunner: StubManagedCodexLoginRunner(
                result: CodexLoginRunner.Result(outcome: .failed(status: 1), output: "nope")),
            identityReader: StubManagedCodexIdentityReader.emails([]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        await #expect(throws: ManagedCodexAccountServiceError.loginFailed) {
            try await service.authenticateManagedAccount()
        }

        #expect(FileManager.default.fileExists(atPath: outsideHome.path))
        #expect(store.snapshot.accounts.isEmpty)
    }

    @Test
    func `remove deletes managed home under managed root`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("accounts/account-a", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let accountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let account = ManagedCodexAccount(
            id: accountID,
            email: "user@example.com",
            managedHomePath: home.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let store = InMemoryManagedCodexAccountStore(
            accounts: ManagedCodexAccountSet(version: 1, accounts: [account]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.emails([]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        try await service.removeManagedAccount(id: account.id)

        #expect(store.snapshot.accounts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.path) == false)
    }

    @Test
    func `remove keeps remaining managed account records`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstHome = root.appendingPathComponent("accounts/account-a", isDirectory: true)
        let secondHome = root.appendingPathComponent("accounts/account-b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstID = try #require(UUID(uuidString: "AAAAAAAA-1111-1111-1111-111111111111"))
        let secondID = try #require(UUID(uuidString: "BBBBBBBB-2222-2222-2222-222222222222"))
        let first = ManagedCodexAccount(
            id: firstID,
            email: "first@example.com",
            managedHomePath: firstHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let second = ManagedCodexAccount(
            id: secondID,
            email: "second@example.com",
            managedHomePath: secondHome.path,
            createdAt: 2,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let store = InMemoryManagedCodexAccountStore(
            accounts: ManagedCodexAccountSet(
                version: 1,
                accounts: [first, second]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.emails([]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        try await service.removeManagedAccount(id: second.id)

        #expect(store.snapshot.accounts.count == 1)
        #expect(store.snapshot.accounts.first?.id == first.id)
        #expect(FileManager.default.fileExists(atPath: secondHome.path) == false)
    }

    @Test
    func `remove keeps persisted account when store write fails`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("accounts/account-a", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let accountID = try #require(UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000"))
        let account = ManagedCodexAccount(
            id: accountID,
            email: "user@example.com",
            managedHomePath: home.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let store = FailingManagedCodexAccountStore(
            accounts: ManagedCodexAccountSet(version: 1, accounts: [account]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.emails([]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        await #expect(throws: TestManagedCodexAccountStoreError.writeFailed) {
            try await service.removeManagedAccount(id: account.id)
        }

        #expect(store.snapshot.accounts.count == 1)
        #expect(store.snapshot.accounts.first?.managedHomePath == home.path)
        #expect(FileManager.default.fileExists(atPath: home.path))
    }

    @Test
    func `remove fails closed for home outside managed root`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outsideRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        let accountID = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"))
        let account = ManagedCodexAccount(
            id: accountID,
            email: "user@example.com",
            managedHomePath: outsideRoot.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let store = InMemoryManagedCodexAccountStore(
            accounts: ManagedCodexAccountSet(version: 1, accounts: [account]))
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactory(root: root),
            loginRunner: StubManagedCodexLoginRunner.success,
            identityReader: StubManagedCodexIdentityReader.emails([]),
            workspaceResolver: StubManagedCodexWorkspaceResolver())

        await #expect(throws: ManagedCodexAccountServiceError.unsafeManagedHome(account.managedHomePath)) {
            try await service.removeManagedAccount(id: account.id)
        }

        #expect(store.snapshot.accounts.count == 1)
        #expect(FileManager.default.fileExists(atPath: outsideRoot.path))
    }
}

private final class InMemoryManagedCodexAccountStore: ManagedCodexAccountStoring, @unchecked Sendable {
    var snapshot: ManagedCodexAccountSet

    init(accounts: ManagedCodexAccountSet) {
        self.snapshot = accounts
    }

    func loadAccounts() throws -> ManagedCodexAccountSet {
        self.snapshot
    }

    func storeAccounts(_ accounts: ManagedCodexAccountSet) throws {
        self.snapshot = accounts
    }

    func ensureFileExists() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private final class FailingManagedCodexAccountStore: ManagedCodexAccountStoring, @unchecked Sendable {
    var snapshot: ManagedCodexAccountSet

    init(accounts: ManagedCodexAccountSet) {
        self.snapshot = accounts
    }

    func loadAccounts() throws -> ManagedCodexAccountSet {
        self.snapshot
    }

    func storeAccounts(_ accounts: ManagedCodexAccountSet) throws {
        _ = accounts
        throw TestManagedCodexAccountStoreError.writeFailed
    }

    func ensureFileExists() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private final class TestManagedCodexHomeFactory: ManagedCodexHomeProducing, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var index: Int = 0

    init(root: URL) {
        self.root = root
    }

    private func nextPathComponent() -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.index += 1
        return "accounts/account-\(self.index)"
    }

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(self.nextPathComponent(), isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private struct UnsafeManagedCodexHomeFactory: ManagedCodexHomeProducing {
    let root: URL
    let homeURL: URL

    func makeHomeURL() -> URL {
        self.homeURL
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private struct StubManagedCodexLoginRunner: ManagedCodexLoginRunning {
    let result: CodexLoginRunner.Result

    func run(homePath: String, timeout: TimeInterval) async -> CodexLoginRunner.Result {
        self.result
    }

    static let success = StubManagedCodexLoginRunner(
        result: CodexLoginRunner.Result(outcome: .success, output: "ok"))
}

private enum TestManagedCodexAccountStoreError: Error, Equatable {
    case writeFailed
}

private final class StubManagedCodexIdentityReader: ManagedCodexIdentityReading, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [CodexAuthBackedAccount]

    init(identities: [CodexAuthBackedAccount]) {
        self.identities = identities
    }

    func loadAccountIdentity(homePath _: String) throws -> CodexAuthBackedAccount {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.identities.isEmpty else {
            return CodexAuthBackedAccount(identity: .unresolved, email: nil, plan: nil)
        }
        return self.identities.removeFirst()
    }

    static func emails(_ emails: [String]) -> StubManagedCodexIdentityReader {
        StubManagedCodexIdentityReader(identities: emails.map { email in
            CodexAuthBackedAccount(
                identity: CodexIdentityResolver.resolve(accountId: nil, email: email),
                email: email,
                plan: "Pro")
        })
    }

    static func accounts(_ accounts: [CodexAuthBackedAccount]) -> StubManagedCodexIdentityReader {
        StubManagedCodexIdentityReader(identities: accounts)
    }
}

private struct StubManagedCodexWorkspaceResolver: ManagedCodexWorkspaceResolving {
    let identities: [String: CodexOpenAIWorkspaceIdentity]

    init(identities: [String: CodexOpenAIWorkspaceIdentity] = [:]) {
        self.identities = identities
    }

    func resolveWorkspaceIdentity(
        homePath _: String,
        providerAccountID: String) async -> CodexOpenAIWorkspaceIdentity?
    {
        self.identities[providerAccountID]
    }
}
