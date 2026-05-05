import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexAccountPromotionPlanningTests {
    @Test
    func `planner converges from direct auth identities without snapshot help`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPlanningTests-converges")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFileWithoutEmail(accountID: "acct-alpha")

        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)

        switch plan {
        case let .none(reason):
            #expect(reason == .targetMatchesLiveAuthIdentity)
        case .reject, .importNew, .refreshExisting, .repairExisting:
            Issue.record("Expected convergence plan")
        }
    }

    @Test
    func `planner refreshes already managed account when readable home identity matches live`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPlanningTests-refresh")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let existingManagedLive = try container.createManagedAccount(
            persistedEmail: "legacy@example.com",
            authEmail: "alpha@example.com",
            authAccountID: "acct-alpha",
            persistedProviderAccountID: nil)
        try container.persistAccounts([target, existingManagedLive])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")

        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)

        switch plan {
        case let .refreshExisting(destination, reason):
            #expect(destination.persisted.id == existingManagedLive.id)
            #expect(reason == .readableHomeIdentityMatch)
        case .none, .reject, .importNew, .repairExisting:
            Issue.record("Expected refresh plan")
        }
    }

    @Test
    func `planner uses repair for persisted provider match before any import fallback`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPlanningTests-repair-before-import")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let staleManaged = ManagedCodexAccount(
            id: UUID(),
            email: "alpha@example.com",
            providerAccountID: "acct-alpha",
            workspaceLabel: "Personal",
            workspaceAccountID: "acct-alpha",
            managedHomePath: container.managedHomesURL
                .appendingPathComponent(UUID().uuidString, isDirectory: true).path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        try container.persistAccounts([target, staleManaged])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")

        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)

        switch plan {
        case let .repairExisting(destination, reason):
            #expect(destination.persisted.id == staleManaged.id)
            #expect(reason == .persistedProviderMatchWithMissingHome)
        case .none, .reject, .importNew, .refreshExisting:
            Issue.record("Expected repair plan")
        }
    }

    @Test
    func `planner rejects persisted provider match when readable home belongs to a different account`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPlanningTests-conflicting-readable-home")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let conflictingManaged = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authEmail: "gamma@example.com",
            authAccountID: "acct-gamma",
            persistedProviderAccountID: "acct-alpha",
            useAuthAccountIDAsPersistedProviderAccountID: false)
        try container.persistAccounts([target, conflictingManaged])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")

        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)

        switch plan {
        case let .reject(reason):
            #expect(reason == .conflictingReadableManagedHome)
        case .none, .importNew, .refreshExisting, .repairExisting:
            Issue.record("Expected reject plan")
        }
    }

    @Test
    func `planner uses legacy email repair instead of import when provider account upgrades old record`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPlanningTests-legacy-repair")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let legacyManaged = ManagedCodexAccount(
            id: UUID(),
            email: "alpha@example.com",
            providerAccountID: nil,
            workspaceLabel: nil,
            workspaceAccountID: nil,
            managedHomePath: container.managedHomesURL
                .appendingPathComponent(UUID().uuidString, isDirectory: true).path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: nil)
        try container.persistAccounts([target, legacyManaged])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")

        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)

        switch plan {
        case let .repairExisting(destination, reason):
            #expect(destination.persisted.id == legacyManaged.id)
            #expect(reason == .persistedLegacyEmailMatch)
        case .none, .reject, .importNew, .refreshExisting:
            Issue.record("Expected legacy email repair plan")
        }
    }

    @Test
    func `planner imports when same email belongs to a different provider account workspace`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPlanningTests-import",
            workspaceIdentities: [
                "acct-personal": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "acct-personal",
                    workspaceLabel: "Personal"),
            ])
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "alice@example.com",
            authAccountID: "acct-team",
            workspaceLabel: "Team",
            workspaceAccountID: "acct-team")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "alice@example.com", accountID: "acct-personal")

        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)

        switch plan {
        case let .importNew(reason):
            #expect(reason == .noExistingManagedDestination)
        case .none, .reject, .refreshExisting, .repairExisting:
            Issue.record("Expected import plan")
        }
    }

    @Test
    func `planner rejects api key only live auth`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPlanningTests-api-key")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        _ = try container.writeLiveAPIKeyAuthFile()

        let context = try await self.makeContext(container: container, targetID: target.id)
        let plan = CodexDisplacedLivePreservationPlanner().makePlan(context: context)

        switch plan {
        case let .reject(reason):
            #expect(reason == .liveAPIKeyOnlyUnsupported)
        case .none, .importNew, .refreshExisting, .repairExisting:
            Issue.record("Expected reject plan")
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
