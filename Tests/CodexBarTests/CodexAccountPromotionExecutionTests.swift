import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct CodexAccountPromotionExecutionTests {
    @Test
    func `displaced auth is private before publication and failure removes imported home`() async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "promotion-private-publication")
        defer { container.tearDown() }
        let target = try container.createManagedAccount(persistedEmail: "beta@example.com", authAccountID: "acct-beta")
        try container.persistAccounts([target])
        let live = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        let context = try await self.makeContext(container: container, targetID: target.id)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: container.fileStore, homeFactory: container.homeFactory, fileManager: .default)
        let inspectStaged: @Sendable (URL) throws -> Void = { staged in
            guard staged.lastPathComponent == "auth.json" else { return }
            let directory = staged.deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect(try Data(contentsOf: staged) == live)
            throw CancellationError()
        }
        CredentialFileWriter.$beforePublishForTesting.withValue(inspectStaged) {
            #expect(throws: CodexAccountPromotionError.displacedLiveImportFailed) {
                try executor.execute(plan: .importNew(reason: .noExistingManagedDestination), context: context)
            }
        }
        #expect(try container.liveAuthData() == live)
        #expect(try container.managedHomeURLs().count == 1)
        #expect(try container.loadAccounts().accounts.count == 1)
    }

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
    func `executor import repairs an explicit workspace only collision`() async throws {
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

        #expect(result == .alreadyManaged(managedAccountID: concurrentManaged.id))
        let accounts = try container.loadAccounts().accounts
        let repaired = try #require(accounts.first(where: { $0.id == concurrentManaged.id }))
        #expect(repaired.providerAccountID == "acct-alpha")
        #expect(repaired.workspaceAccountID == "acct-alpha")
        #expect(repaired.managedHomePath != concurrentHomeURL.path)
        #expect(try container.managedAuthData(for: repaired) == liveAuthData)
    }

    @Test
    func `executor import repairs a raced collision with matching readable auth identity`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-import-matching-readable-collision")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let concurrentManaged = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha",
            workspaceLabel: "Personal",
            workspaceAccountID: "acct-alpha",
            plan: "Team")
        let concurrentAuthData = try container.managedAuthData(for: concurrentManaged)
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")
        #expect(concurrentAuthData != liveAuthData)
        let context = try await self.makeContext(container: container, targetID: target.id)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: ConcurrentDuplicateManagedCodexAccountStore(
                base: container.fileStore,
                concurrentAccount: concurrentManaged),
            homeFactory: container.homeFactory,
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            fileManager: .default)

        let result = try executor.execute(plan: .importNew(reason: .noExistingManagedDestination), context: context)

        #expect(result == .alreadyManaged(managedAccountID: concurrentManaged.id))
        let accounts = try container.loadAccounts().accounts
        let repaired = try #require(accounts.first(where: { $0.id == concurrentManaged.id }))
        #expect(accounts.count == 2)
        #expect(repaired.managedHomePath != concurrentManaged.managedHomePath)
        #expect(try container.managedAuthData(for: repaired) == liveAuthData)
    }

    @Test
    func `executor import repair keeps a raced home when the staged home reuses its path`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-import-same-home-collision")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let sharedHomeURL = container.managedHomesURL.appendingPathComponent(
            "shared-raced-home",
            isDirectory: true)
        let concurrentManaged = ManagedCodexAccount(
            id: UUID(),
            email: "alpha@example.com",
            providerAccountID: "acct-alpha",
            workspaceLabel: "Personal",
            workspaceAccountID: "acct-alpha",
            managedHomePath: sharedHomeURL.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")
        let context = try await self.makeContext(container: container, targetID: target.id)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: ConcurrentDuplicateManagedCodexAccountStore(
                base: container.fileStore,
                concurrentAccount: concurrentManaged),
            homeFactory: FixedManagedHomeFactory(
                base: container.homeFactory,
                stagedHomeURL: sharedHomeURL),
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            fileManager: .default)

        let result = try executor.execute(plan: .importNew(reason: .noExistingManagedDestination), context: context)

        #expect(result == .alreadyManaged(managedAccountID: concurrentManaged.id))
        let accounts = try container.loadAccounts().accounts
        let repaired = try #require(accounts.first(where: { $0.id == concurrentManaged.id }))
        #expect(repaired.managedHomePath == sharedHomeURL.path)
        #expect(FileManager.default.fileExists(atPath: sharedHomeURL.path))
        #expect(try container.managedAuthData(for: repaired) == liveAuthData)
        #expect(try container.liveAuthData() == liveAuthData)
    }

    @Test
    func `executor import rejects a raced workspace collision with conflicting readable auth`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-import-conflicting-collision")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let concurrentManaged = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-gamma",
            persistedProviderAccountID: nil,
            useAuthAccountIDAsPersistedProviderAccountID: false,
            workspaceLabel: "Personal",
            workspaceAccountID: "acct-alpha")
        let concurrentAuthData = try container.managedAuthData(for: concurrentManaged)
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")
        let context = try await self.makeContext(container: container, targetID: target.id)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: ConcurrentDuplicateManagedCodexAccountStore(
                base: container.fileStore,
                concurrentAccount: concurrentManaged),
            homeFactory: container.homeFactory,
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            fileManager: .default)

        #expect(throws: CodexAccountPromotionError.displacedLiveManagedAccountConflict) {
            try executor.execute(plan: .importNew(reason: .noExistingManagedDestination), context: context)
        }

        let accounts = try container.loadAccounts().accounts
        let persistedConflict = try #require(accounts.first(where: { $0.id == concurrentManaged.id }))
        #expect(accounts.count == 2)
        #expect(persistedConflict.workspaceAccountID == "acct-alpha")
        #expect(persistedConflict.managedHomePath == concurrentManaged.managedHomePath)
        #expect(try container.managedAuthData(for: persistedConflict) == concurrentAuthData)
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(try container.managedHomeURLs().count == 2)
    }

    enum DestinationChange: CaseIterable {
        case foreign, unreadable, missing, sameAccount, readFailure
    }

    @Test(arguments: [false, true], DestinationChange.allCases)
    func `executor revalidates repair and refresh destinations`(
        repair: Bool,
        change: DestinationChange) async throws
    {
        let container = try CodexAccountPromotionTestContainer(suiteName: "promotion-destination-drift")
        defer { container.tearDown() }
        let target = try container.createManagedAccount(persistedEmail: "beta@example.com", authAccountID: "acct-beta")
        let destination = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha",
            legacyRecord: true,
            writeAuthFile: !repair)
        try container.persistAccounts([target, destination])
        let liveData = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)
        let authURL = CodexAuthFingerprint.authFileURL(homePath: destination.managedHomePath)
        let replacement: Data? = switch change {
        case .foreign: try container.managedAuthData(for: target)
        case .unreadable: Data("not auth json".utf8)
        case .missing: nil
        case .sameAccount, .readFailure: liveData + Data("\n".utf8)
        }
        if let replacement {
            try replacement.write(to: authURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: authURL.path) {
            try FileManager.default.removeItem(at: authURL)
        }
        let reader: any CodexAuthMaterialReading = change == .readFailure
            ? FailingDestinationAuthReader(homePath: destination.managedHomePath) : DefaultCodexAuthMaterialReader()
        let executor = CodexDisplacedLivePreservationExecutor(
            store: container.fileStore, homeFactory: container.homeFactory, authMaterialReader: reader)
        if change == .foreign || change == .readFailure || change == .unreadable && !repair {
            #expect(throws: CodexAccountPromotionError.displacedLiveManagedAccountConflict) {
                try executor.execute(plan: plan, context: context)
            }
            #expect(try Data(contentsOf: authURL) == replacement)
            #expect(try container.loadAccounts().account(id: destination.id)?.authFingerprint == destination
                .authFingerprint)
        } else {
            #expect(try executor
                .execute(plan: plan, context: context) == .alreadyManaged(managedAccountID: destination.id))
            #expect(try Data(contentsOf: authURL) == liveData)
        }
        #expect(try container.liveAuthData() == liveData)
    }

    @Test
    func `executor verifies written auth before committing its fingerprint`() async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "promotion-corrupted-publication")
        defer { container.tearDown() }
        let target = try container.createManagedAccount(persistedEmail: "beta@example.com", authAccountID: "acct-beta")
        let destination = try container.createManagedAccount(
            persistedEmail: "alpha@example.com", authAccountID: "acct-alpha")
        try container.persistAccounts([target, destination])
        let liveData = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        let foreignData = try container.managedAuthData(for: target)
        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: container.fileStore,
            homeFactory: container.homeFactory)
        // Corrupt the actual staged file on both main and the fixed path, independently of verification reads.
        let corruptPublication: @Sendable (URL) throws -> Void = { staged in
            if staged.lastPathComponent == "auth.json" { try foreignData.write(to: staged) }
        }
        CredentialFileWriter.$beforePublishForTesting.withValue(corruptPublication) {
            #expect(throws: CodexAccountPromotionError.displacedLiveManagedAccountConflict) {
                try executor.execute(plan: plan, context: context)
            }
        }
        #expect(try container.managedAuthData(for: destination) == foreignData)
        #expect(try container.liveAuthData() == liveData)
        #expect(try container.loadAccounts().account(id: destination.id)?.authFingerprint == destination
            .authFingerprint)
    }

    @Test(arguments: [false, true])
    func `executor import rejects a raced legacy collision that cannot be safely replaced`(readFailure: Bool)
        async throws
    {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionExecutionTests-import-legacy-conflicting-collision")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let concurrentManaged = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-gamma",
            legacyRecord: true)
        let concurrentAuthData = try container.managedAuthData(for: concurrentManaged)
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveOAuthAuthFile(email: "alpha@example.com")
        let context = try await self.makeContext(container: container, targetID: target.id)
        let executor = CodexDisplacedLivePreservationExecutor(
            store: ConcurrentDuplicateManagedCodexAccountStore(
                base: container.fileStore,
                concurrentAccount: concurrentManaged),
            homeFactory: container.homeFactory,
            authMaterialReader: readFailure
                ? FailingDestinationAuthReader(homePath: concurrentManaged.managedHomePath)
                : DefaultCodexAuthMaterialReader(),
            fileManager: .default)

        #expect(throws: CodexAccountPromotionError.displacedLiveManagedAccountConflict) {
            try executor.execute(plan: .importNew(reason: .noExistingManagedDestination), context: context)
        }

        let accounts = try container.loadAccounts().accounts
        let persistedConcurrent = try #require(accounts.first(where: { $0.id == concurrentManaged.id }))
        #expect(accounts.count == 2)
        #expect(persistedConcurrent.managedHomePath == concurrentManaged.managedHomePath)
        #expect(persistedConcurrent.providerAccountID == nil)
        #expect(try container.managedAuthData(for: persistedConcurrent) == concurrentAuthData)
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(try container.managedHomeURLs().count == 2)
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
            snapshotLoader: container.settings,
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

private struct FailingDestinationAuthReader: CodexAuthMaterialReading {
    let homePath: String

    func readAuthData(homeURL: URL) throws -> Data? {
        if homeURL.path == self.homePath { throw CocoaError(.fileReadNoPermission) }
        return try DefaultCodexAuthMaterialReader().readAuthData(homeURL: homeURL)
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
