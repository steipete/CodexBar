import CodexBarCore
import Foundation
import Testing

struct CodexVisibleAccountProjectionRuntimeIdentityTests {
    @Test
    func `runtime provider identity supplies missing managed workspace id`() throws {
        let accountID = UUID()
        let storedAccount = ManagedCodexAccount(
            id: accountID,
            email: "user@example.com",
            workspaceAccountID: nil,
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [storedAccount],
            activeStoredAccount: storedAccount,
            liveSystemAccount: nil,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: accountID),
            hasUnreadableAddedAccountStore: false,
            storedAccountRuntimeIdentities: [accountID: .providerAccount(id: " Account-Live ")])

        let account = try #require(CodexVisibleAccountProjection.make(from: snapshot).visibleAccounts.first)

        #expect(account.workspaceAccountID == "account-live")
        #expect(account.selectionSource == .managedAccount(id: accountID))
    }
}
