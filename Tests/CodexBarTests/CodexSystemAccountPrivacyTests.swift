import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexSystemAccountPrivacyTests {
    private static let firstSlot = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let secondSlot = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test
    func `private submenu hides all account emails and email-like workspace labels`() {
        let accounts = [
            Self.account("a", workspace: "Personal", storedID: Self.firstSlot),
            Self.account("b", workspace: "Acme", storedID: Self.secondSlot),
            Self.account("c", workspace: "Acme"),
            Self.account("d", workspace: "Team owner@example.com"),
            Self.account("e", workspace: "用户@example.com"),
            Self.account("f", workspace: "  "),
        ]
        let items = Self.items(Self.projection(accounts, live: "a"), hide: true)
        #expect(items.count == accounts.count)
        #expect(items.map(\.title) == [
            "Account 1", "Account 2 · Acme", "Account 3 · Acme", "Account 4 · Team", "Account 5", "Account 6",
        ])
        #expect(items.allSatisfy { !$0.title.contains("@") && !$0.title.isEmpty })
        #expect(Set(items.map(\.title)).count == accounts.count)
    }

    @Test
    func `privacy off preserves exact display names including Personal and discriminators`() {
        let projection = Self.projection([
            Self.account("a", email: "same@example.com", workspace: "Personal", storedID: Self.firstSlot),
            Self.account("b", email: "same@example.com", workspace: "Personal", storedID: Self.secondSlot),
        ])
        let items = Self.items(projection, hide: false)
        #expect(items.map(\.title) == projection.visibleAccounts.map(\.displayName))
        #expect(items.allSatisfy { $0.title.contains("Personal") && $0.title.contains("@") })
        #expect(Set(items.map(\.title)).count == 2)
    }

    @Test
    func `privacy toggles only titles and leaves promotion targets and checked state unchanged`() {
        let projection = Self.projection([
            Self.account("a", storedID: Self.firstSlot),
            Self.account("b", storedID: Self.secondSlot),
            Self.account("c"),
        ], live: "a")
        let publicItems = Self.items(projection, hide: false)
        let privateItems = Self.items(projection, hide: true)
        #expect(Self.items(projection, hide: false) == publicItems)
        #expect(Self.items(projection, hide: true) == privateItems)
        #expect(privateItems.map(\.action) == publicItems.map(\.action))
        #expect(privateItems.map(\.isEnabled) == [false, true, false])
        #expect(privateItems.map(\.isEnabled) == publicItems.map(\.isEnabled))
        #expect(privateItems.map(\.isChecked) == [true, false, false])
        #expect(privateItems.map(\.isChecked) == publicItems.map(\.isChecked))
        #expect(privateItems.map(\.action) == [
            .requestCodexSystemPromotion(Self.firstSlot), .requestCodexSystemPromotion(Self.secondSlot), nil,
        ])
        let blocked = Self.items(projection, hide: true, blocked: true)
        #expect(blocked.allSatisfy { !$0.isEnabled })
        #expect(blocked.map(\.action) == privateItems.map(\.action))
        #expect(blocked.map(\.isChecked) == privateItems.map(\.isChecked))
    }

    @Test
    func `private ordinals survive display reordering and promotion to the live identity`() {
        let accounts = [
            Self.account("stored-b", storedID: Self.secondSlot),
            Self.account("stored-a", storedID: Self.firstSlot),
        ]
        let original = Self.items(Self.projection(accounts), hide: true)
        let reversed = Self.items(Self.projection(Array(accounts.reversed())), hide: true)
        #expect(reversed.map(\.title) == Array(original.map(\.title).reversed()))
        let promoted = Self.items(Self.projection([
            accounts[0], Self.account("live-a", storedID: Self.firstSlot),
        ], live: "live-a"), hide: true)
        #expect(promoted.map(\.title) == original.map(\.title))
        #expect(promoted.map(\.isChecked) == [false, true])
    }

    @Test
    func `existing submenu visibility rules remain intact`() {
        for hide in [false, true] {
            #expect(Self.items(Self.projection([]), hide: hide).isEmpty)
            #expect(Self.items(Self.projection([Self.account("live")], live: "live"), hide: hide).isEmpty)
            let projection = Self.projection([Self.account("stored", storedID: Self.firstSlot)])
            #expect(Self.items(projection, hide: hide).count == 1)
            #expect(Self.items(projection, hide: hide, blocked: true).isEmpty)
        }
    }

    private static func items(
        _ projection: CodexVisibleAccountProjection,
        hide: Bool,
        blocked: Bool = false) -> [MenuDescriptor.SubmenuItem]
    {
        CodexProviderImplementation.systemAccountMenuItems(
            projection: projection, hidePersonalInfo: hide, isInteractionBlocked: blocked)
    }

    private static func projection(
        _ accounts: [CodexVisibleAccount],
        live: String? = nil) -> CodexVisibleAccountProjection
    {
        CodexVisibleAccountProjection(
            visibleAccounts: accounts,
            activeVisibleAccountID: nil,
            liveVisibleAccountID: live,
            hasUnreadableAddedAccountStore: false)
    }

    private static func account(
        _ id: String,
        email: String? = nil,
        workspace: String? = nil,
        storedID: UUID? = nil) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: id,
            email: email ?? "\(id)@example.com",
            workspaceLabel: workspace,
            storedAccountID: storedID,
            selectionSource: .liveSystem,
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
    }
}
