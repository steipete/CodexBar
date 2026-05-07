import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexAccountsSectionStateTests {
    @Test
    func `system badge shows for merged live row`() {
        let accountID = UUID()
        let mergedLiveAccount = CodexVisibleAccount(
            id: "merged@example.com",
            email: "merged@example.com",
            storedAccountID: accountID,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [mergedLiveAccount],
            activeVisibleAccountID: mergedLiveAccount.id,
            liveVisibleAccountID: mergedLiveAccount.id,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: false,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: false,
            notice: nil)

        #expect(state.showsLiveBadge(for: mergedLiveAccount))
    }

    @Test
    func `system promotion availability uses live visible account and stored account id`() {
        let managedAccountID = UUID()
        let liveAccount = CodexVisibleAccount(
            id: "live@example.com",
            email: "live@example.com",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: false,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let managedAccount = CodexVisibleAccount(
            id: "managed:\(managedAccountID.uuidString.lowercased())",
            email: "managed@example.com",
            storedAccountID: managedAccountID,
            selectionSource: .managedAccount(id: managedAccountID),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [liveAccount, managedAccount],
            activeVisibleAccountID: managedAccount.id,
            liveVisibleAccountID: liveAccount.id,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: false,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: false,
            notice: nil)

        #expect(state.canPromoteToSystem(liveAccount) == false)
        #expect(state.canPromoteToSystem(managedAccount))
    }

    @Test
    func `system promotion controls disable while conflicting work is running`() {
        let managedAccountID = UUID()
        let liveAccount = CodexVisibleAccount(
            id: "live@example.com",
            email: "live@example.com",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: false,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let managedAccount = CodexVisibleAccount(
            id: "managed:\(managedAccountID.uuidString.lowercased())",
            email: "managed@example.com",
            storedAccountID: managedAccountID,
            selectionSource: .managedAccount(id: managedAccountID),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [liveAccount, managedAccount],
            activeVisibleAccountID: managedAccount.id,
            liveVisibleAccountID: liveAccount.id,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: true,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: false,
            notice: nil)

        #expect(state.isSystemSelectionDisabled)
        #expect(state.canPromoteToSystem(managedAccount) == false)
    }

    @Test
    func `system display does not fall back when no live account exists`() {
        let managedAccountID = UUID()
        let managedAccount = CodexVisibleAccount(
            id: "managed:\(managedAccountID.uuidString.lowercased())",
            email: "managed@example.com",
            storedAccountID: managedAccountID,
            selectionSource: .managedAccount(id: managedAccountID),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [managedAccount],
            activeVisibleAccountID: managedAccount.id,
            liveVisibleAccountID: nil,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: false,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: false,
            notice: nil)

        #expect(state.systemVisibleAccount == nil)
        #expect(state.showsSystemPicker)
        #expect(state.systemDisplayName == "No system account")
    }

    @Test
    func `remove in flight blocks add reauth and remove actions`() {
        let managedAccountID = UUID()
        let managedAccount = CodexVisibleAccount(
            id: "managed:\(managedAccountID.uuidString.lowercased())",
            email: "managed@example.com",
            storedAccountID: managedAccountID,
            selectionSource: .managedAccount(id: managedAccountID),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [managedAccount],
            activeVisibleAccountID: managedAccount.id,
            liveVisibleAccountID: nil,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: true,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: false,
            notice: nil)

        #expect(state.canAddAccount == false)
        #expect(state.canReauthenticate(managedAccount) == false)
        #expect(state.canRemove(managedAccount) == false)
    }

    @Test
    func `promotion in flight blocks add reauth and remove actions`() {
        let managedAccountID = UUID()
        let managedAccount = CodexVisibleAccount(
            id: "managed:\(managedAccountID.uuidString.lowercased())",
            email: "managed@example.com",
            storedAccountID: managedAccountID,
            selectionSource: .managedAccount(id: managedAccountID),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let state = CodexAccountsSectionState(
            visibleAccounts: [managedAccount],
            activeVisibleAccountID: managedAccount.id,
            liveVisibleAccountID: nil,
            hasUnreadableManagedAccountStore: false,
            isAuthenticatingManagedAccount: false,
            authenticatingManagedAccountID: nil,
            isRemovingManagedAccount: false,
            isAuthenticatingLiveAccount: false,
            isPromotingSystemAccount: true,
            notice: nil)

        #expect(state.canAddAccount == false)
        #expect(state.canReauthenticate(managedAccount) == false)
        #expect(state.canRemove(managedAccount) == false)
    }
}
