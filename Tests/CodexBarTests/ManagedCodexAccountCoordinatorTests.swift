import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ManagedCodexAccountCoordinatorTests {
    @Test
    func `coordinator exposes in flight state and rejects overlapping managed authentication`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existingAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let runner = BlockingManagedCodexLoginRunner()
        let service = ManagedCodexAccountService(
            store: InMemoryManagedCodexAccountStoreForCoordinatorTests(
                accounts: ManagedCodexAccountSet(version: 1, accounts: [])),
            homeFactory: CoordinatorTestManagedCodexHomeFactory(root: root),
            loginRunner: runner,
            identityReader: CoordinatorStubManagedCodexIdentityReader(email: "user@example.com"))
        let coordinator = ManagedCodexAccountCoordinator(service: service)

        let authTask = Task { try await coordinator.authenticateManagedAccount(existingAccountID: existingAccountID) }
        await runner.waitUntilStarted()

        #expect(coordinator.isAuthenticatingManagedAccount)
        #expect(coordinator.authenticatingManagedAccountID == existingAccountID)

        await #expect(throws: ManagedCodexAccountCoordinatorError.authenticationInProgress) {
            try await coordinator.authenticateManagedAccount()
        }

        await runner.resume()
        let account = try await authTask.value

        #expect(account.email == "user@example.com")
        #expect(coordinator.isAuthenticatingManagedAccount == false)
        #expect(coordinator.authenticatingManagedAccountID == nil)
    }
}

private actor BlockingManagedCodexLoginRunner: ManagedCodexLoginRunning {
    private var waiters: [CheckedContinuation<CodexLoginRunner.Result, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func run(homePath _: String, timeout _: TimeInterval) async -> CodexLoginRunner.Result {
        self.didStart = true
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func resume() {
        let result = CodexLoginRunner.Result(outcome: .success, output: "ok")
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }
}

private final class InMemoryManagedCodexAccountStoreForCoordinatorTests: ManagedCodexAccountStoring,
@unchecked Sendable {
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

private final class CoordinatorTestManagedCodexHomeFactory: ManagedCodexHomeProducing, @unchecked Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private final class CoordinatorStubManagedCodexIdentityReader: ManagedCodexIdentityReading, @unchecked Sendable {
    let email: String

    init(email: String) {
        self.email = email
    }

    func loadAccountIdentity(homePath _: String) throws -> CodexAuthBackedAccount {
        CodexAuthBackedAccount(
            identity: CodexIdentityResolver.resolve(accountId: nil, email: self.email),
            email: self.email,
            plan: "Pro")
    }
}
