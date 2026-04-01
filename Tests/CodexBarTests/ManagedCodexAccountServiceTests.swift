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
            identityReader: StubManagedCodexIdentityReader.emails(["user@example.com", "user@example.com"]))

        let first = try await service.authenticateManagedAccount()
        let second = try await service.authenticateManagedAccount()
        let snapshot = try store.loadAccounts()

        #expect(first.id == second.id)
        #expect(second.email == "user@example.com")
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
            identityReader: StubManagedCodexIdentityReader.emails(["second@example.com"]))

        let authenticated = try await service.authenticateManagedAccount()

        #expect(store.snapshot.accounts.count == 2)
        #expect(authenticated.email == "second@example.com")
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
            identityReader: StubManagedCodexIdentityReader.emails(["user@example.com"]))

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
    func `reauth reconciles by canonical email before existing account id`() async throws {
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
            email: "alpha@example.com",
            managedHomePath: alphaHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let betaAccount = ManagedCodexAccount(
            id: betaID,
            email: "beta@example.com",
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
            identityReader: StubManagedCodexIdentityReader.emails(["BETA@example.com"]))

        let account = try await service.authenticateManagedAccount(existingAccountID: alphaAccount.id)

        let storedAlpha = try #require(store.snapshot.account(id: alphaAccount.id))
        let storedBeta = try #require(store.snapshot.account(id: betaAccount.id))
        #expect(account.id == betaAccount.id)
        #expect(store.snapshot.accounts.count == 2)
        #expect(storedAlpha.email == "alpha@example.com")
        #expect(storedAlpha.managedHomePath == alphaHome.path)
        #expect(storedBeta.email == "beta@example.com")
        #expect(storedBeta.managedHomePath.hasPrefix(root.standardizedFileURL.path + "/"))
        #expect(storedBeta.managedHomePath != betaHome.path)
        #expect(FileManager.default.fileExists(atPath: alphaHome.path))
        #expect(FileManager.default.fileExists(atPath: betaHome.path) == false)
        #expect(FileManager.default.fileExists(atPath: storedBeta.managedHomePath))
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
            identityReader: StubManagedCodexIdentityReader.emails([]))

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
            identityReader: StubManagedCodexIdentityReader.emails([]))

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
            identityReader: StubManagedCodexIdentityReader.emails([]))

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
            identityReader: StubManagedCodexIdentityReader.emails([]))

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
            identityReader: StubManagedCodexIdentityReader.emails([]))

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

private struct UnsafeManagedCodexHomeFactory: ManagedCodexHomeProducing, Sendable {
    let root: URL
    let homeURL: URL

    func makeHomeURL() -> URL {
        self.homeURL
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private struct StubManagedCodexLoginRunner: ManagedCodexLoginRunning, Sendable {
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
    private var emails: [String]

    init(emails: [String]) {
        self.emails = emails
    }

    func loadAccountIdentity(homePath _: String) throws -> CodexAuthBackedAccount {
        self.lock.lock()
        defer { self.lock.unlock() }
        let email = self.emails.isEmpty ? nil : self.emails.removeFirst()
        return CodexAuthBackedAccount(
            identity: CodexIdentityResolver.resolve(accountId: nil, email: email),
            email: email,
            plan: "Pro")
    }

    static func emails(_ emails: [String]) -> StubManagedCodexIdentityReader {
        StubManagedCodexIdentityReader(emails: emails)
    }
}
