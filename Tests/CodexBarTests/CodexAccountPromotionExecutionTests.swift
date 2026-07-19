import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexAccountPromotionExecutionTests {
    @Test
    func `executor import store failure cleans up imported home and maps managed store error`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-import-cleanup")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        let context = try await self.makeContext(container: container, targetID: target.id)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: RecordingManagedCodexAccountStore(base: container.fileStore) { _ in
                throw PromotionTestError.storeWriteFailed
            },
            homeFactory: container.homeFactory,
            fileManager: .default)

        #expect(throws: CodexAccountPromotionError.managedStoreCommitFailed) {
            try executor.execute(plan: .importNew(reason: .noExistingManagedDestination), context: context)
        }

        #expect(try container.managedHomeURLs().count == 1)
        #expect(try container.loadAccounts().accounts.count == 1)
    }

    @Test
    func `executor refresh failure leaves live auth untouched and keeps copied managed auth`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-refresh-failure")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let existingManagedLive = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        try container.persistAccounts([target, existingManagedLive])
        let originalManagedAuthData = try container.managedAuthData(for: existingManagedLive)
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha",
            apiKey: "sk-refreshed-live")
        let originalLiveAuthData = try #require(try container.liveAuthData())
        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: RecordingManagedCodexAccountStore(base: container.fileStore) { accounts in
                if accounts.account(id: existingManagedLive.id)?
                    .lastAuthenticatedAt != existingManagedLive.lastAuthenticatedAt
                {
                    throw PromotionTestError.storeWriteFailed
                }
            },
            homeFactory: container.homeFactory,
            fileManager: .default)

        #expect(throws: CodexAccountPromotionError.managedStoreCommitFailed) {
            try executor.execute(plan: plan, context: context)
        }

        let accounts = try container.loadAccounts().accounts
        let persistedManagedLive = try #require(accounts.first(where: { $0.id == existingManagedLive.id }))
        #expect(try container.liveAuthData() == originalLiveAuthData)
        #expect(try container.managedAuthData(for: persistedManagedLive) != originalManagedAuthData)
        #expect(try container.managedAuthData(for: persistedManagedLive) == liveAuthData)
    }

    @Test
    func `executor import verifies persisted account after concurrent duplicate collision`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-import-collision-repair")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let concurrentID = UUID()
        let concurrentHomeURL = container.managedHomesURL.appendingPathComponent(
            concurrentID.uuidString,
            isDirectory: true)
        try FileManager.default.createDirectory(at: concurrentHomeURL, withIntermediateDirectories: true)
        let concurrentManaged = ManagedCodexAccount(
            id: concurrentID,
            email: "alpha@example.com",
            providerAccountID: "acct-alpha",
            workspaceLabel: "Personal",
            workspaceAccountID: "acct-alpha",
            managedHomePath: concurrentHomeURL.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        let context = try await self.makeContext(container: container, targetID: target.id)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: ConcurrentDuplicateManagedCodexAccountStore(
                base: container.fileStore,
                concurrentAccount: concurrentManaged),
            homeFactory: container.homeFactory,
            fileManager: .default)

        let result = try executor.execute(plan: .importNew(reason: .noExistingManagedDestination), context: context)

        #expect(result.displacedLiveDisposition == .alreadyManaged(managedAccountID: concurrentManaged.id))
        let accounts = try container.loadAccounts().accounts
        let repaired = try #require(accounts.first(where: { $0.id == concurrentManaged.id }))
        #expect(repaired.managedHomePath != concurrentHomeURL.path)
        #expect(try container.managedAuthData(for: repaired) == liveAuthData)
    }

    @Test
    func `executor refresh filesystem failure maps to managed store error`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-refresh-filesystem-failure")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let existingManagedLive = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        try container.persistAccounts([target, existingManagedLive])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)

        let managedHomeURL = URL(fileURLWithPath: existingManagedLive.managedHomePath, isDirectory: true)
        try FileManager.default.removeItem(at: managedHomeURL)
        try Data("blocked".utf8).write(to: managedHomeURL)

        let executor = CodexDisplacedLivePreservationExecutor(
            store: container.fileStore,
            homeFactory: container.homeFactory,
            fileManager: .default)

        #expect(throws: CodexAccountPromotionError.managedStoreCommitFailed) {
            try executor.execute(plan: plan, context: context)
        }
    }

    @Test
    func `executor legacy import repair ignores provider backed rows with the same email`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-legacy-import-provider-same-email")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let providerManaged = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-existing")
        try container.persistAccounts([target, providerManaged])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com")
        let context = try await self.makeContext(container: container, targetID: target.id)
        let originalProviderManaged = try #require(try container.loadAccounts().account(id: providerManaged.id))

        let executor = CodexDisplacedLivePreservationExecutor(
            store: DroppingLegacyImportedAccountStore(
                base: container.fileStore,
                preservedProviderBackedAccount: originalProviderManaged),
            homeFactory: container.homeFactory,
            fileManager: .default)

        #expect(throws: CodexAccountPromotionError.managedStoreCommitFailed) {
            try executor.execute(plan: .importNew(reason: .noExistingManagedDestination), context: context)
        }

        let persistedProviderManaged = try #require(try container.loadAccounts().account(id: providerManaged.id))
        #expect(persistedProviderManaged.providerAccountID == originalProviderManaged.providerAccountID)
        #expect(persistedProviderManaged.managedHomePath == originalProviderManaged.managedHomePath)
    }

    @Test
    func `executor reject preserves stable error mapping`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-reject-mapping")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        let context = try await self.makeContext(container: container, targetID: target.id)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: container.fileStore,
            homeFactory: container.homeFactory,
            fileManager: .default)

        #expect(throws: CodexAccountPromotionError.liveAccountAPIKeyOnlyUnsupported) {
            try executor.execute(plan: .reject(reason: .liveAPIKeyOnlyUnsupported), context: context)
        }
        #expect(throws: CodexAccountPromotionError.liveAccountUnreadable) {
            try executor.execute(plan: .reject(reason: .liveUnreadable), context: context)
        }
        #expect(throws: CodexAccountPromotionError.liveAccountMissingIdentityForPreservation) {
            try executor.execute(plan: .reject(reason: .liveIdentityMissingForPreservation), context: context)
        }
    }

    @Test
    func `executor rejects target as preservation destination`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-target-destination")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        let context = try await self.makeContext(container: container, targetID: target.id)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: container.fileStore,
            homeFactory: container.homeFactory,
            fileManager: .default)

        #expect(throws: CodexAccountPromotionError.managedStoreCommitFailed) {
            try executor.execute(
                plan: .refreshExisting(
                    destination: context.target,
                    reason: .readableHomeIdentityMatch),
                context: context)
        }
    }

    private func makeContext(
        container: CodexAccountPromotionTestContainer,
        targetID: UUID)
        async throws -> PreparedPromotionContext
    {
        let builder = PreparedPromotionContextBuilder(
            store: container.fileStore,
            workspaceResolver: container.workspaceResolver,
            snapshotLoader: SettingsStoreCodexAccountReconciliationSnapshotLoader(settingsStore: container.settings),
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            baseEnvironment: container.baseEnvironment,
            fileManager: .default)
        return try await builder.build(targetID: targetID)
    }
}

private final class ConcurrentDuplicateManagedCodexAccountStore: ManagedCodexAccountStoring, @unchecked Sendable {
    let base: any ManagedCodexAccountStoring
    let concurrentAccount: ManagedCodexAccount
    private var didInjectConcurrentAccount = false

    init(base: any ManagedCodexAccountStoring, concurrentAccount: ManagedCodexAccount) {
        self.base = base
        self.concurrentAccount = concurrentAccount
    }

    func loadAccounts() throws -> ManagedCodexAccountSet {
        if self.didInjectConcurrentAccount == false {
            self.didInjectConcurrentAccount = true
            let current = try self.base.loadAccounts()
            try self.base.storeAccounts(ManagedCodexAccountSet(
                version: current.version,
                accounts: current.accounts + [self.concurrentAccount]))
        }
        return try self.base.loadAccounts()
    }

    func storeAccounts(_ accounts: ManagedCodexAccountSet) throws {
        try self.base.storeAccounts(accounts)
    }

    func ensureFileExists() throws -> URL {
        try self.base.ensureFileExists()
    }
}

private final class DroppingLegacyImportedAccountStore: ManagedCodexAccountStoring, @unchecked Sendable {
    let base: any ManagedCodexAccountStoring
    let preservedProviderBackedAccount: ManagedCodexAccount

    init(base: any ManagedCodexAccountStoring, preservedProviderBackedAccount: ManagedCodexAccount) {
        self.base = base
        self.preservedProviderBackedAccount = preservedProviderBackedAccount
    }

    func loadAccounts() throws -> ManagedCodexAccountSet {
        try self.base.loadAccounts()
    }

    func storeAccounts(_ accounts: ManagedCodexAccountSet) throws {
        let filteredAccounts = accounts.accounts.filter {
            $0.id == self.preservedProviderBackedAccount.id || $0.providerAccountID != nil
        }
        try self.base.storeAccounts(ManagedCodexAccountSet(
            version: accounts.version,
            accounts: filteredAccounts))
    }

    func ensureFileExists() throws -> URL {
        try self.base.ensureFileExists()
    }
}
