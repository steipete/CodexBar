import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexAccountPromotionPreparationTests {
    @Test
    func `builder carries direct auth identities for target and live`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPreparationTests-direct-identities",
            workspaceIdentities: [
                "acct-alpha": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "acct-alpha",
                    workspaceLabel: "Personal"),
                "acct-beta": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "acct-beta",
                    workspaceLabel: "Team"),
            ])
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")

        let builder = PreparedPromotionContextBuilder(
            store: container.fileStore,
            workspaceResolver: container.workspaceResolver,
            snapshotLoader: SettingsStoreCodexAccountReconciliationSnapshotLoader(settingsStore: container.settings),
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            baseEnvironment: container.baseEnvironment,
            fileManager: .default)

        let context = try await builder.build(targetID: target.id)

        #expect(context.target.authIdentity?.identity == .providerAccount(id: "acct-beta"))
        #expect(context.target.authIdentity?.workspaceLabel == "Team")
        #expect(context.live.authIdentity?.identity == .providerAccount(id: "acct-alpha"))
        #expect(context.live.authIdentity?.workspaceLabel == "Personal")
    }

    @Test
    func `builder preserves target missing auth as degraded home state`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPreparationTests-target-missing-auth")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: target.managedHomePath, isDirectory: true)
                .appendingPathComponent("auth.json", isDirectory: false))

        let builder = PreparedPromotionContextBuilder(
            store: container.fileStore,
            workspaceResolver: container.workspaceResolver,
            snapshotLoader: SettingsStoreCodexAccountReconciliationSnapshotLoader(settingsStore: container.settings),
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            baseEnvironment: container.baseEnvironment,
            fileManager: .default)

        let context = try await builder.build(targetID: target.id)

        switch context.target.homeState {
        case let .missing(homeURL):
            #expect(homeURL.path == target.managedHomePath)
        case .readable, .unreadable:
            Issue.record("Expected target auth to be represented as missing")
        }
        #expect(context.target.authIdentity == nil)
        #expect(context.target.persistedIdentity.identity == .providerAccount(id: "acct-beta"))
    }

    @Test
    func `builder keeps persisted and direct home identity views separate`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPreparationTests-persisted-vs-direct",
            workspaceIdentities: [
                "acct-alpha": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "acct-alpha",
                    workspaceLabel: "Personal"),
            ])
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let legacy = try container.createManagedAccount(
            persistedEmail: "legacy@example.com",
            authEmail: "alpha@example.com",
            authAccountID: "acct-alpha",
            persistedProviderAccountID: nil,
            useAuthAccountIDAsPersistedProviderAccountID: false)
        try container.persistAccounts([target, legacy])

        let builder = PreparedPromotionContextBuilder(
            store: container.fileStore,
            workspaceResolver: container.workspaceResolver,
            snapshotLoader: SettingsStoreCodexAccountReconciliationSnapshotLoader(settingsStore: container.settings),
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            baseEnvironment: container.baseEnvironment,
            fileManager: .default)

        let context = try await builder.build(targetID: target.id)
        let preparedLegacy = try #require(context.storedManagedAccounts.first(where: { $0.persisted.id == legacy.id }))

        #expect(preparedLegacy.persistedIdentity.email == "legacy@example.com")
        #expect(preparedLegacy.persistedIdentity.identity == .emailOnly(normalizedEmail: "legacy@example.com"))
        #expect(preparedLegacy.authIdentity?.email == "alpha@example.com")
        #expect(preparedLegacy.authIdentity?.identity == .providerAccount(id: "acct-alpha"))
        #expect(preparedLegacy.authIdentity?.workspaceLabel == "Personal")
    }
}
