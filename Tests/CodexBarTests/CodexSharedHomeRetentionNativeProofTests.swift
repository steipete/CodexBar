import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Exercise the production JSON store and managed-home cleanup against synthetic files only.
@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct CodexSharedHomeRetentionNativeProofTests {
    @Test
    func `real managed account removal preserves a home still referenced by a sibling record`() async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "shared-home-removal-native-proof")
        defer { container.tearDown() }

        let sibling = try container.createManagedAccount(
            persistedEmail: "sibling@example.com",
            authAccountID: "acct-sibling")
        let sharedHomeURL = URL(fileURLWithPath: sibling.managedHomePath, isDirectory: true)
        let removed = ManagedCodexAccount(
            id: UUID(),
            email: "removed@example.com",
            providerAccountID: "acct-removed",
            managedHomePath: sibling.managedHomePath,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        try container.persistAccounts([removed, sibling])
        let authBefore = try container.managedAuthData(for: sibling)
        let service = ManagedCodexAccountService(
            store: container.fileStore,
            homeFactory: container.homeFactory,
            loginRunner: UnusedManagedCodexLoginRunner(),
            identityReader: container.identityReader,
            workspaceResolver: container.workspaceResolver)

        try await service.removeManagedAccount(id: removed.id)

        #expect(FileManager.default.fileExists(atPath: sharedHomeURL.path))
        #expect(try container.managedAuthData(for: sibling) == authBefore)
        let reloaded = try FileManagedCodexAccountStore(fileURL: container.managedStoreURL).loadAccounts()
        #expect(reloaded.accounts.map(\.id) == [sibling.id])

        try await service.removeManagedAccount(id: sibling.id)

        #expect(FileManager.default.fileExists(atPath: sharedHomeURL.path) == false)
        #expect(try container.loadAccounts().accounts.isEmpty)
    }

    @Test
    func `real raced import repair preserves a home still referenced by a foreign-written record`() async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "shared-home-race-native-proof")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        let raced = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        let sharedHomeURL = URL(fileURLWithPath: raced.managedHomePath, isDirectory: true)
        let sharedAuthData = try container.managedAuthData(for: raced)
        let sibling = ManagedCodexAccount(
            id: UUID(),
            email: "other@example.com",
            providerAccountID: "acct-other",
            managedHomePath: raced.managedHomePath,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let builder = PreparedPromotionContextBuilder(
            store: container.fileStore,
            workspaceResolver: container.workspaceResolver,
            snapshotLoader: container.settings,
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            baseEnvironment: container.baseEnvironment,
            fileManager: .default)
        let context = try await builder.build(targetID: target.id)

        // A second real store publishes a collision after the preservation context was prepared.
        let foreignStore = FileManagedCodexAccountStore(fileURL: container.managedStoreURL)
        let foreignSet = try foreignStore.loadAccounts()
        try foreignStore.storeAccounts(ManagedCodexAccountSet(
            version: foreignSet.version,
            accounts: foreignSet.accounts + [raced, sibling]))
        let executor = CodexDisplacedLivePreservationExecutor(
            store: container.fileStore,
            homeFactory: container.homeFactory)

        let result = try executor.execute(plan: .importNew(reason: .noExistingManagedDestination), context: context)

        #expect(result == .alreadyManaged(managedAccountID: raced.id))
        #expect(FileManager.default.fileExists(atPath: sharedHomeURL.path))
        #expect(try container.managedAuthData(for: sibling) == sharedAuthData)
        let reloaded = try foreignStore.loadAccounts().accounts
        #expect(reloaded.count == 3)
        #expect(reloaded.contains { $0.id == sibling.id && $0.managedHomePath == sharedHomeURL.path })
        let repaired = try #require(reloaded.first { $0.id == raced.id })
        #expect(repaired.managedHomePath != sharedHomeURL.path)
        #expect(try container.managedAuthData(for: repaired) == liveAuthData)
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(try container.managedHomeURLs().count == 3)
    }
}

private struct UnusedManagedCodexLoginRunner: ManagedCodexLoginRunning {
    func run(homePath _: String, timeout _: TimeInterval) async -> CLILoginRunner.Result {
        fatalError("Managed account removal must not invoke login")
    }
}
