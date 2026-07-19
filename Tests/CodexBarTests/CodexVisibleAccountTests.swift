import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct CodexVisibleAccountTests {
    @Test
    func `menu display name suppresses personal workspace label`() {
        let personal = CodexVisibleAccount(
            id: "personal",
            email: "user@example.com",
            workspaceLabel: "Personal",
            workspaceAccountID: "account-personal",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let team = CodexVisibleAccount(
            id: "team",
            email: "user@example.com",
            workspaceLabel: "Team Alpha",
            workspaceAccountID: "account-team",
            storedAccountID: nil,
            selectionSource: .managedAccount(id: UUID()),
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)

        #expect(personal.displayName == "user@example.com — Personal")
        #expect(personal.menuDisplayName == "user@example.com")
        #expect(personal.menuWorkspaceLabel == nil)
        #expect(team.displayName == "user@example.com — Team Alpha")
        #expect(team.menuDisplayName == "user@example.com — Team Alpha")
        #expect(team.menuWorkspaceLabel == "Team Alpha")
    }
}
