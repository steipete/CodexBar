import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexWorkspaceDisplayTests {
    @Test(arguments: [nil, "", " \n\t ", "Personal", "Business", " Team Alpha "] as [String?])
    func `same email workspace collisions have stable opaque display labels`(label: String?) throws {
        let accounts = Self.accounts(label: label)
        let projection = Self.project(accounts)
        let displayed = projection.visibleAccounts
        #expect(Set(displayed.map(\.displayName)).count == 2)
        #expect(Set(displayed.map(\.menuDisplayName)).count == 2)
        for (raw, account) in zip(accounts, displayed) {
            let discriminator = try #require(account.displayDiscriminator)
            #expect(discriminator.count == 8)
            #expect(account.displayName == account.menuDisplayName)
            #expect(account.displayName.contains(discriminator))
            #expect(try !account.displayName.contains(#require(account.workspaceAccountID)))
            #expect(account.workspaceLabel == raw.workspaceLabel)
            #expect(account.selectionSource == raw.selectionSource)
            #expect(account.authFingerprint == raw.authFingerprint)
            #expect(PersonalInfoRedactor.redactEmail(account.menuDisplayName, isEnabled: true).isEmpty)
            #expect(PersonalInfoRedactor.redactEmail(account.menuDisplayName, isEnabled: false) == account.displayName)
        }
        #expect(Self.project(displayed).visibleAccounts == displayed)
        #expect(Self.project(Array(accounts.reversed())).visibleAccounts.map(\.displayName) == displayed.reversed()
            .map(\.displayName))
    }

    @Test
    func `nil and Personal labels collide only when their menu names match`() {
        let personal = Self.account(id: 0, label: "Personal")
        let unnamed = Self.account(id: 1, label: nil)
        let named = Self.account(id: 2, label: "Engineering")
        let displayed = Self.project([personal, unnamed, named]).visibleAccounts
        #expect(displayed[0].displayDiscriminator != nil)
        #expect(displayed[1].displayDiscriminator != nil)
        #expect(displayed[2].displayDiscriminator == nil)
        #expect(displayed[2].displayName == "user@example.com — Engineering")
        #expect(Self.project([personal]).visibleAccounts.first?.menuDisplayName == "user@example.com")
    }

    @Test
    func `workspace discriminator survives active selection and system promotion`() throws {
        let managed = (0..<2).map { index in
            ManagedCodexAccount(
                id: Self.accountID(index),
                email: "user@example.com",
                providerAccountID: "workspace-\(index)",
                workspaceLabel: "Business",
                workspaceAccountID: "workspace-\(index)",
                managedHomePath: "/tmp/synthetic-codex-\(index)",
                createdAt: 1,
                updatedAt: 2,
                lastAuthenticatedAt: 3)
        }
        func project(activeIndex: Int, liveIndex: Int?) -> [CodexVisibleAccount] {
            let live = liveIndex.map { index in
                ObservedSystemCodexAccount(
                    email: "user@example.com",
                    workspaceLabel: "Business",
                    workspaceAccountID: "workspace-\(index)",
                    codexHomePath: "/tmp/synthetic-codex-system",
                    observedAt: Date(),
                    identity: .providerAccount(id: "workspace-\(index)"))
            }
            return CodexVisibleAccountProjection.make(from: CodexAccountReconciliationSnapshot(
                storedAccounts: managed,
                activeStoredAccount: managed[activeIndex],
                liveSystemAccount: live,
                matchingStoredAccountForLiveSystemAccount: liveIndex.map { managed[$0] },
                activeSource: .managedAccount(id: managed[activeIndex].id),
                hasUnreadableAddedAccountStore: false,
                storedAccountRuntimeIdentities: Dictionary(uniqueKeysWithValues: managed.enumerated().map {
                    ($0.element.id, .providerAccount(id: "workspace-\($0.offset)"))
                }))).visibleAccounts
        }
        let original = project(activeIndex: 0, liveIndex: nil)
        for accounts in [project(activeIndex: 1, liveIndex: nil), project(activeIndex: 1, liveIndex: 1)] {
            for expected in original {
                let actual = try #require(accounts.first { $0.workspaceAccountID == expected.workspaceAccountID })
                #expect(actual.displayName == expected.displayName)
                #expect(actual.menuDisplayName == expected.menuDisplayName)
                #expect(actual.storedAccountID == expected.storedAccountID)
            }
        }
    }

    @Test
    func `compact switcher keeps the workspace discriminator visible`() throws {
        let accounts = Self.project(Self.accounts(label: "Same long Business workspace name")).visibleAccounts
        let view = CodexAccountSwitcherView(
            accounts: accounts,
            selectedAccountID: accounts[0].id,
            width: 220,
            onSelect: { _ in })
        let titles = view._test_buttonTitles()
        #expect(Set(titles).count == 2)
        for (account, title) in zip(accounts, titles) {
            #expect(try title.hasSuffix(#require(account.displayDiscriminator)))
        }
        #expect(view._test_buttonToolTips() == accounts.map(\.menuDisplayName))
    }

    @Test
    func `separate profile homes in one workspace retain distinct labels`() {
        let paths = ["/tmp/synthetic-profile-a", "/tmp/synthetic-profile-b"]
        let profiles = paths.map { path in
            ObservedSystemCodexAccount(
                email: "user@example.com",
                workspaceLabel: "Business",
                workspaceAccountID: "shared-workspace",
                codexHomePath: path,
                observedAt: Date(),
                identity: .providerAccount(id: "shared-workspace"))
        }
        func project(activePath: String) -> [CodexVisibleAccount] {
            CodexVisibleAccountProjection.make(from: CodexAccountReconciliationSnapshot(
                storedAccounts: [],
                activeStoredAccount: nil,
                liveSystemAccount: nil,
                profileHomeAccounts: profiles,
                matchingStoredAccountForLiveSystemAccount: nil,
                activeSource: .profileHome(path: activePath),
                hasUnreadableAddedAccountStore: false)).visibleAccounts
        }
        let accounts = project(activePath: paths[0])
        #expect(accounts.count == 2)
        #expect(Set(accounts.map(\.displayName)).count == 2)
        #expect(Set(accounts.map(\.menuDisplayName)).count == 2)
        #expect(accounts.map(\.displayName) == project(activePath: paths[1]).map(\.displayName))
        for (account, path) in zip(accounts, paths) {
            #expect(!account.displayName.contains(path))
            #expect(!account.displayName.contains("shared-workspace"))
            #expect(account.workspaceAccountID == "shared-workspace")
        }
    }

    @Test(arguments: [8, 12])
    func `crowded switcher fits complete workspace discriminators`(count: Int) throws {
        let accounts = Self.project(Self.accounts(label: nil, count: count)).visibleAccounts
        let view = CodexAccountSwitcherView(
            accounts: accounts, selectedAccountID: accounts[0].id, width: 310, onSelect: { _ in })
        view.layoutSubtreeIfNeeded()
        let buttons = Self.buttons(in: view)
        #expect(buttons.count == count)
        for (account, button) in zip(accounts, buttons) {
            let discriminator = try #require(account.displayDiscriminator)
            #expect(button.title.hasSuffix(discriminator))
            let font = try #require(button.font)
            let textWidth = ceil((button.title as NSString).size(withAttributes: [.font: font]).width)
            let contentWidth = button.bounds.width - button.contentPadding.left - button.contentPadding.right
            #expect(textWidth <= contentWidth)
        }
    }

    private static func buttons(in view: NSView) -> [PaddedToggleButton] {
        view.subviews.flatMap { subview in
            if let button = subview as? PaddedToggleButton { return [button] }
            return self.buttons(in: subview)
        }
    }

    static func project(_ accounts: [CodexVisibleAccount]) -> CodexVisibleAccountProjection {
        CodexVisibleAccountProjection(
            visibleAccounts: accounts,
            activeVisibleAccountID: accounts.first?.id,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
    }

    static func accounts(label: String?, count: Int = 2) -> [CodexVisibleAccount] {
        (0..<count).map { self.account(id: $0, label: label) }
    }

    private static func accountID(_ index: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index))")!
    }

    private static func account(id: Int, label: String?) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: "synthetic-\(id)",
            email: "user@example.com",
            workspaceLabel: label,
            workspaceAccountID: "synthetic-workspace-\(id)",
            storedAccountID: self.accountID(id),
            selectionSource: .managedAccount(id: self.accountID(id)),
            isActive: id == 0,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
    }
}
