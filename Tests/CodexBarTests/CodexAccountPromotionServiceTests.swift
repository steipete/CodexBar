import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexAccountPromotionServiceTests {
    @Test
    func `happy path promotion swaps target auth into live home`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-happy-path")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        container.settings.codexActiveSource = .managedAccount(id: target.id)
        try container.removeLiveAuthFile()

        let targetAuthData = try container.managedAuthData(for: target)
        let result = try await container.makeService().promoteManagedAccount(id: target.id)
        let accounts = try container.loadAccounts().accounts

        #expect(result.targetManagedAccountID == target.id)
        #expect(result.outcome == .promoted)
        #expect(result.displacedLiveDisposition == .none)
        #expect(result.didMutateLiveAuth)
        #expect(result.resultingActiveSource == .liveSystem)
        #expect(try container.liveAuthData() == targetAuthData)
        #expect(accounts.count == 1)
        #expect(accounts.first?.id == target.id)
        #expect(container.settings.codexActiveSource == .liveSystem)
        #expect(container.usageStore.snapshots[.codex]?.accountEmail(for: .codex) == "beta@example.com")
    }

    @Test
    func `displaced live oauth is imported before target auth is promoted`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-displaced-import",
            workspaceIdentities: [
                "acct-alpha": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "acct-alpha",
                    workspaceLabel: "Personal"),
            ])
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        container.settings.codexActiveSource = .managedAccount(id: target.id)
        let displacedLiveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")

        let result = try await container.makeService().promoteManagedAccount(id: target.id)
        let accounts = try container.loadAccounts().accounts
        let importedID: UUID
        switch result.displacedLiveDisposition {
        case let .imported(managedAccountID):
            importedID = managedAccountID
        case .none, .alreadyManaged:
            Issue.record("Expected displaced live account import")
            throw PromotionTestError.unexpectedDisposition
        }
        let imported = try #require(accounts.first(where: { $0.id == importedID }))

        #expect(accounts.count == 2)
        #expect(imported.email == "alpha@example.com")
        #expect(imported.providerAccountID == "acct-alpha")
        #expect(imported.workspaceLabel == "Personal")
        #expect(imported.workspaceAccountID == "acct-alpha")
        #expect(try container.managedAuthData(for: imported) == displacedLiveAuthData)
        #expect(try container.liveAuthData() == container.managedAuthData(for: target))
    }

    @Test
    func `displaced live already managed uses reconciliation identity dedupe`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-already-managed")
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
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha",
            apiKey: "sk-fresh-live")

        let result = try await container.makeService().promoteManagedAccount(id: target.id)
        let accounts = try container.loadAccounts().accounts
        let refreshedManagedLive = try #require(accounts.first(where: { $0.id == existingManagedLive.id }))

        #expect(result.displacedLiveDisposition == .alreadyManaged(managedAccountID: existingManagedLive.id))
        #expect(accounts.count == 2)
        #expect(accounts.contains(where: { $0.id == existingManagedLive.id }))
        #expect(try container.managedAuthData(for: refreshedManagedLive) == liveAuthData)
        #expect(try container.liveAuthData() == container.managedAuthData(for: target))
    }

    @Test
    func `provider only live auth refreshes existing managed account using persisted email`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-already-managed-no-email")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let existingManagedLive = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        try container.persistAccounts([target, existingManagedLive])
        let liveAuthData = try container.writeLiveOAuthAuthFileWithoutEmail(accountID: "acct-alpha")

        let result = try await container.makeService().promoteManagedAccount(id: target.id)
        let accounts = try container.loadAccounts().accounts
        let refreshedManagedLive = try #require(accounts.first(where: { $0.id == existingManagedLive.id }))

        #expect(result.displacedLiveDisposition == .alreadyManaged(managedAccountID: existingManagedLive.id))
        #expect(refreshedManagedLive.email == "alpha@example.com")
        #expect(refreshedManagedLive.providerAccountID == "acct-alpha")
        #expect(try container.managedAuthData(for: refreshedManagedLive) == liveAuthData)
    }

    @Test
    func `provider only live auth matching target converges and keeps managed active source`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-provider-only-convergence")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveOAuthAuthFileWithoutEmail(accountID: "acct-alpha")
        container.settings.codexActiveSource = .managedAccount(id: target.id)

        let result = try await container.makeService().promoteManagedAccount(id: target.id)

        #expect(result.outcome == .convergedNoOp)
        #expect(result.displacedLiveDisposition == .none)
        #expect(result.didMutateLiveAuth == false)
        #expect(result.resultingActiveSource == .managedAccount(id: target.id))
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(try container.loadAccounts().accounts.count == 1)
        #expect(container.settings.codexActiveSource == .managedAccount(id: target.id))
    }

    @Test
    func `provider only live auth matching target converges when target managed auth is missing`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-provider-only-convergence-missing-target-auth")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        try container.persistAccounts([target])
        container.settings.codexActiveSource = .managedAccount(id: target.id)
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: target.managedHomePath, isDirectory: true)
                .appendingPathComponent("auth.json", isDirectory: false))
        let liveAuthData = try container.writeLiveOAuthAuthFileWithoutEmail(accountID: "acct-alpha")

        let result = try await container.makeService().promoteManagedAccount(id: target.id)

        #expect(result.outcome == .convergedNoOp)
        #expect(result.displacedLiveDisposition == .none)
        #expect(result.didMutateLiveAuth == false)
        #expect(result.resultingActiveSource == .managedAccount(id: target.id))
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(container.settings.codexActiveSource == .managedAccount(id: target.id))
    }

    @Test
    func `snapshot convergence no op does not require target managed auth file`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-snapshot-convergence-with-missing-target-auth")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        try container.persistAccounts([target])
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: target.managedHomePath, isDirectory: true)
                .appendingPathComponent("auth.json", isDirectory: false))
        container.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            codexHomePath: container.liveHomeURL.path,
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")

        let result = try await container.makeService().promoteManagedAccount(id: target.id)

        #expect(result.outcome == .convergedNoOp)
        #expect(result.displacedLiveDisposition == .none)
        #expect(result.didMutateLiveAuth == false)
        #expect(try container.liveAuthData() == liveAuthData)
    }

    @Test
    func `convergence no-op does not rewrite live auth or import displaced live`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-convergence")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")

        let result = try await container.makeService().promoteManagedAccount(id: target.id)

        #expect(result.outcome == .convergedNoOp)
        #expect(result.displacedLiveDisposition == .none)
        #expect(result.didMutateLiveAuth == false)
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(try container.loadAccounts().accounts.count == 1)
        #expect(container.settings.codexActiveSource == .liveSystem)
    }

    @Test
    func `same email different workspace imports displaced live as a distinct managed account`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-same-email-different-workspace",
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

        let result = try await container.makeService().promoteManagedAccount(id: target.id)
        let importedID: UUID
        switch result.displacedLiveDisposition {
        case let .imported(managedAccountID):
            importedID = managedAccountID
        case .none, .alreadyManaged:
            Issue.record("Expected same-email different-workspace import")
            throw PromotionTestError.unexpectedDisposition
        }
        let accounts = try container.loadAccounts().accounts
        let imported = try #require(accounts.first(where: { $0.id == importedID }))

        #expect(accounts.count == 2)
        #expect(imported.id != target.id)
        #expect(imported.email == "alice@example.com")
        #expect(imported.providerAccountID == "acct-personal")
        #expect(imported.workspaceLabel == "Personal")
        #expect(imported.workspaceAccountID == "acct-personal")
    }

    @Test
    func `mixed api key and oauth live auth still preserves displaced live identity`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-mixed-auth-preservation",
            workspaceIdentities: [
                "acct-alpha": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "acct-alpha",
                    workspaceLabel: "Personal"),
            ])
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha",
            apiKey: "sk-mixed-live")

        let result = try await container.makeService().promoteManagedAccount(id: target.id)
        let importedID: UUID
        switch result.displacedLiveDisposition {
        case let .imported(managedAccountID):
            importedID = managedAccountID
        case .none, .alreadyManaged:
            Issue.record("Expected displaced live import for mixed auth material")
            throw PromotionTestError.unexpectedDisposition
        }
        let imported = try #require(try container.loadAccounts().accounts.first(where: { $0.id == importedID }))

        #expect(imported.email == "alpha@example.com")
        #expect(imported.providerAccountID == "acct-alpha")
        #expect(imported.workspaceLabel == "Personal")
    }

    @Test
    func `store commit failure leaves live auth untouched because promotion preserves before mutating`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-store-failure")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")
        let swapper = RecordingCodexLiveAuthSwapper()
        let store = RecordingManagedCodexAccountStore(base: container.fileStore) { _ in
            throw PromotionTestError.storeWriteFailed
        }

        await #expect(throws: CodexAccountPromotionError.managedStoreCommitFailed) {
            try await container.makeService(
                store: store,
                liveAuthSwapper: swapper).promoteManagedAccount(id: target.id)
        }

        #expect(swapper.swapCallCount == 0)
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(try container.loadAccounts().accounts.count == 1)
        #expect(try container.loadAccounts().accounts.first?.id == target.id)
        #expect(try container.managedHomeURLs().count == 1)
    }

    @Test
    func `refresh store failure leaves existing managed metadata stale after auth copy`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-refresh-store-failure")
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
        let swapper = RecordingCodexLiveAuthSwapper()
        let store = RecordingManagedCodexAccountStore(base: container.fileStore) { accounts in
            if accounts.account(id: existingManagedLive.id)?
                .lastAuthenticatedAt != existingManagedLive.lastAuthenticatedAt
            {
                throw PromotionTestError.storeWriteFailed
            }
        }

        await #expect(throws: CodexAccountPromotionError.managedStoreCommitFailed) {
            try await container.makeService(
                store: store,
                liveAuthSwapper: swapper).promoteManagedAccount(id: target.id)
        }

        let accounts = try container.loadAccounts().accounts
        let persistedManagedLive = try #require(accounts.first(where: { $0.id == existingManagedLive.id }))
        #expect(swapper.swapCallCount == 0)
        #expect(try container.managedAuthData(for: persistedManagedLive) != originalManagedAuthData)
        #expect(try container.managedAuthData(for: persistedManagedLive) == liveAuthData)
        #expect(persistedManagedLive.lastAuthenticatedAt == existingManagedLive.lastAuthenticatedAt)
    }

    @Test
    func `already managed refresh resolves workspace metadata from live auth home`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-already-managed-workspace-refresh")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let existingManagedLive = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha",
            workspaceLabel: "Stale",
            workspaceAccountID: "acct-alpha")
        try container.persistAccounts([target, existingManagedLive])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")

        let service = CodexAccountPromotionService(
            store: container.fileStore,
            homeFactory: container.homeFactory,
            identityReader: container.identityReader,
            workspaceResolver: HomePathWorkspaceResolver(
                byHomePath: [
                    container.liveHomeURL.path: CodexOpenAIWorkspaceIdentity(
                        workspaceAccountID: "acct-alpha",
                        workspaceLabel: "Fresh"),
                    existingManagedLive.managedHomePath: CodexOpenAIWorkspaceIdentity(
                        workspaceAccountID: "acct-alpha",
                        workspaceLabel: "Stale"),
                ]),
            snapshotLoader: SettingsStoreCodexAccountReconciliationSnapshotLoader(settingsStore: container.settings),
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            liveAuthSwapper: DefaultCodexLiveAuthSwapper(),
            activeSourceWriter: SettingsStoreCodexActiveSourceWriter(settingsStore: container.settings),
            accountScopedRefresher: UsageStoreCodexAccountScopedRefresher(usageStore: container.usageStore),
            baseEnvironment: container.baseEnvironment,
            fileManager: .default)

        let result = try await service.promoteManagedAccount(id: target.id)
        let accounts = try container.loadAccounts().accounts
        let refreshedManagedLive = try #require(accounts.first(where: { $0.id == existingManagedLive.id }))

        #expect(result.displacedLiveDisposition == .alreadyManaged(managedAccountID: existingManagedLive.id))
        #expect(refreshedManagedLive.workspaceLabel == "Fresh")
        #expect(refreshedManagedLive.workspaceAccountID == "acct-alpha")
    }

    @Test
    func `live swap failure keeps preserved displaced live import in the managed store`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-swap-failure")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        container.settings.codexActiveSource = .managedAccount(id: target.id)
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")
        let swapper = RecordingCodexLiveAuthSwapper { _, _ in
            throw PromotionTestError.swapFailed
        }

        await #expect(throws: CodexAccountPromotionError.liveAuthSwapFailed) {
            try await container.makeService(liveAuthSwapper: swapper).promoteManagedAccount(id: target.id)
        }

        let accounts = try container.loadAccounts().accounts
        let imported = try #require(accounts.first(where: { $0.id != target.id }))
        #expect(accounts.count == 2)
        #expect(try container.managedAuthData(for: imported) == liveAuthData)
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(container.settings.codexActiveSource == .managedAccount(id: target.id))
    }

    @Test
    func `target managed auth without email is rejected before swap`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-target-auth-missing-email")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        try container.persistAccounts([target])
        container.settings.codexActiveSource = .managedAccount(id: target.id)
        _ = try container.writeManagedOAuthAuthFileWithoutEmail(for: target, accountID: "acct-alpha")
        let swapper = RecordingCodexLiveAuthSwapper()

        await #expect(throws: CodexAccountPromotionError.targetManagedAccountAuthUnreadable) {
            try await container.makeService(liveAuthSwapper: swapper).promoteManagedAccount(id: target.id)
        }

        #expect(swapper.swapCallCount == 0)
        #expect(try container.liveAuthData() == nil)
        #expect(try container.loadAccounts().accounts.count == 1)
        #expect(container.settings.codexActiveSource == .managedAccount(id: target.id))
    }

    @Test
    func `provider account collision after stale managed home repairs existing record to preserved auth`()
        async throws
    {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-stale-home-collision")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let existingID = UUID()
        let staleHomeURL = container.managedHomesURL.appendingPathComponent(existingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staleHomeURL, withIntermediateDirectories: true)
        let staleManaged = ManagedCodexAccount(
            id: existingID,
            email: "alpha@example.com",
            providerAccountID: "acct-alpha",
            workspaceLabel: "Personal",
            workspaceAccountID: "acct-alpha",
            managedHomePath: staleHomeURL.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        try container.persistAccounts([target, staleManaged])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        let liveAuthData = try #require(try container.liveAuthData())

        let result = try await container.makeService().promoteManagedAccount(id: target.id)
        let accounts = try container.loadAccounts().accounts
        let repairedManaged = try #require(accounts.first(where: { $0.id == staleManaged.id }))

        #expect(result.displacedLiveDisposition == .alreadyManaged(managedAccountID: staleManaged.id))
        #expect(accounts.count == 2)
        #expect(repairedManaged.managedHomePath == staleHomeURL.path)
        #expect(try container.managedAuthData(for: repairedManaged) == liveAuthData)
        #expect(try container.managedHomeURLs().count == 2)
    }

    @Test
    func `legacy email only managed account upgrades to provider identity during promotion`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-legacy-email-upgrade",
            workspaceIdentities: [
                "acct-alpha": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "acct-alpha",
                    workspaceLabel: "Personal"),
            ])
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let legacyID = UUID()
        let legacyHomeURL = container.managedHomesURL.appendingPathComponent(legacyID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyHomeURL, withIntermediateDirectories: true)
        let legacyManaged = ManagedCodexAccount(
            id: legacyID,
            email: "alpha@example.com",
            providerAccountID: nil,
            workspaceLabel: nil,
            workspaceAccountID: nil,
            managedHomePath: legacyHomeURL.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: nil)
        try container.persistAccounts([target, legacyManaged])
        let liveAuthData = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")

        let result = try await container.makeService().promoteManagedAccount(id: target.id)
        let accounts = try container.loadAccounts().accounts
        let upgradedManaged = try #require(accounts.first(where: { $0.id == legacyManaged.id }))

        #expect(result.displacedLiveDisposition == .alreadyManaged(managedAccountID: legacyManaged.id))
        #expect(accounts.count == 2)
        #expect(upgradedManaged.providerAccountID == "acct-alpha")
        #expect(upgradedManaged.workspaceLabel == "Personal")
        #expect(upgradedManaged.workspaceAccountID == "acct-alpha")
        #expect(try container.managedAuthData(for: upgradedManaged) == liveAuthData)
    }

    @Test
    func `unsafe managed home refresh is rejected before auth rewrite`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-unsafe-refresh-home")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let unsafeManagedLive = ManagedCodexAccount(
            id: UUID(),
            email: "alpha@example.com",
            providerAccountID: "acct-alpha",
            workspaceLabel: nil,
            workspaceAccountID: "acct-alpha",
            managedHomePath: container.rootURL.appendingPathComponent("unsafe-home", isDirectory: true).path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        try container.persistAccounts([target, unsafeManagedLive])
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")

        await #expect(throws: CodexAccountPromotionError.displacedLiveImportFailed) {
            try await container.makeService().promoteManagedAccount(id: target.id)
        }

        let accounts = try container.loadAccounts().accounts
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(FileManager.default.fileExists(atPath: unsafeManagedLive.managedHomePath) == false)
        #expect(accounts.count == 2)
        #expect(accounts.contains(where: { $0.id == target.id }))
        #expect(accounts.contains(where: { $0.id == unsafeManagedLive.id }))
    }

    @Test
    func `promotion rejects conflicting readable managed home before overwriting auth`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-conflicting-readable-home")
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
        let liveAuthData = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        let conflictingAuthData = try container.managedAuthData(for: conflictingManaged)

        await #expect(throws: CodexAccountPromotionError.displacedLiveManagedAccountConflict) {
            try await container.makeService().promoteManagedAccount(id: target.id)
        }

        let accounts = try container.loadAccounts().accounts
        let persistedConflict = try #require(accounts.first(where: { $0.id == conflictingManaged.id }))
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(try container.managedAuthData(for: persistedConflict) == conflictingAuthData)
        #expect(accounts.count == 2)
    }

    @Test
    func `api key only live auth is rejected fail closed`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-api-key-only")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveAPIKeyAuthFile()

        await #expect(throws: CodexAccountPromotionError.liveAccountAPIKeyOnlyUnsupported) {
            try await container.makeService().promoteManagedAccount(id: target.id)
        }

        #expect(try container.liveAuthData() == liveAuthData)
        #expect(try container.loadAccounts().accounts.count == 1)
        #expect(try container.loadAccounts().accounts.first?.id == target.id)
    }

    @Test
    func `post promotion refresh re-resolves codex state from the new live auth`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-state-reresolution")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")
        container.seedScopedRefreshState(
            email: "alpha@example.com",
            identity: .providerAccount(id: "acct-alpha"))

        let result = try await container.makeService().promoteManagedAccount(id: target.id)

        #expect(result.outcome == .promoted)
        #expect(container.usageStore.snapshots[.codex]?.accountEmail(for: .codex) == "beta@example.com")
        #expect(container.usageStore.lastCreditsSnapshotAccountKey == "beta@example.com")
        #expect(container.usageStore.lastCodexAccountScopedRefreshGuard?.identity == .providerAccount(id: "acct-beta"))
        #expect(container.usageStore.lastCodexAccountScopedRefreshGuard?.accountKey == "beta@example.com")
    }
}

private struct HomePathWorkspaceResolver: ManagedCodexWorkspaceResolving {
    let byHomePath: [String: CodexOpenAIWorkspaceIdentity]

    func resolveWorkspaceIdentity(
        homePath: String,
        providerAccountID _: String) async -> CodexOpenAIWorkspaceIdentity?
    {
        self.byHomePath[homePath]
    }
}
