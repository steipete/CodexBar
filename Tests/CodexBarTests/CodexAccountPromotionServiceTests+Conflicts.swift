import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension CodexAccountPromotionServiceTests {
    @Test(arguments: [nil, "acct-alpha"] as [String?])
    func `promotion preserves a divergent readable home matched only by legacy email`(
        liveAccountID: String?) async throws
    {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-legacy-email-readable-conflict")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let divergentManaged = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-gamma",
            legacyRecord: true)
        try container.persistAccounts([target, divergentManaged])
        let liveAuthData = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: liveAccountID)
        let divergentAuthData = try container.managedAuthData(for: divergentManaged)
        let managedHomePaths = try Set(container.managedHomeURLs().map(\.path))
        let swapper = RecordingCodexLiveAuthSwapper()

        await #expect(throws: CodexAccountPromotionError.displacedLiveManagedAccountConflict) {
            try await container.makeService(liveAuthSwapper: swapper).promoteManagedAccount(id: target.id)
        }

        let accounts = try container.loadAccounts().accounts
        let persistedDivergent = try #require(accounts.first(where: { $0.id == divergentManaged.id }))
        #expect(try container.liveAuthData() == liveAuthData)
        #expect(try container.managedAuthData(for: persistedDivergent) == divergentAuthData)
        #expect(persistedDivergent.effectiveWorkspaceAccountID == nil)
        #expect(accounts.count == 2)
        #expect(swapper.swapCallCount == 0)
        #expect(try Set(container.managedHomeURLs().map(\.path)) == managedHomePaths)
    }

    @Test
    func `promotion repairs a provider keyed destination while preserving a divergent legacy home`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionServiceTests-provider-repair-preserves-legacy")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let providerBacked = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-alpha",
            writeAuthFile: false)
        let divergentManaged = try container.createManagedAccount(
            persistedEmail: "alpha@example.com",
            authAccountID: "acct-gamma",
            legacyRecord: true)
        try container.persistAccounts([target, providerBacked, divergentManaged])
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")
        let divergentAuthData = try container.managedAuthData(for: divergentManaged)
        let managedHomePaths = try Set(container.managedHomeURLs().map(\.path))
        let swapper = RecordingCodexLiveAuthSwapper()

        let result = try await container.makeService(liveAuthSwapper: swapper)
            .promoteManagedAccount(id: target.id)

        #expect(result.displacedLiveDisposition == .alreadyManaged(managedAccountID: providerBacked.id))
        let accounts = try container.loadAccounts().accounts
        let repaired = try #require(accounts.first(where: { $0.id == providerBacked.id }))
        let persistedDivergent = try #require(accounts.first(where: { $0.id == divergentManaged.id }))
        let persistedTarget = try #require(accounts.first(where: { $0.id == target.id }))
        #expect(accounts.count == 3)
        #expect(repaired.managedHomePath == providerBacked.managedHomePath)
        #expect(repaired.authFingerprint == CodexAuthFingerprint.fingerprint(data: liveAuthData))
        #expect(try container.managedAuthData(for: repaired) == liveAuthData)
        #expect(persistedDivergent.effectiveWorkspaceAccountID == nil)
        #expect(try container.managedAuthData(for: persistedDivergent) == divergentAuthData)
        #expect(try container.liveAuthData() == container.managedAuthData(for: persistedTarget))
        #expect(swapper.swapCallCount == 1)
        #expect(try Set(container.managedHomeURLs().map(\.path)) == managedHomePaths)
    }
}
