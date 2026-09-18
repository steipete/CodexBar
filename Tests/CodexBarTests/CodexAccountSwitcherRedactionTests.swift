import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Hide Personal Info was honored on provider cards but ignored by the Codex account switcher,
/// which rendered raw `email — workspace` titles. These lock in the redacted labels.
@MainActor
struct CodexAccountSwitcherRedactionTests {
    private func account(
        id: String,
        email: String,
        workspace: String? = nil) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: id,
            email: email,
            workspaceLabel: workspace,
            workspaceAccountID: nil,
            authFingerprint: nil,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
    }

    private func label(_ account: CodexVisibleAccount, ordinal: Int?, hide: Bool) -> String {
        CodexAccountSwitcherLabeling.label(
            for: account, ordinal: ordinal, hidePersonalInfo: hide)
    }

    @Test
    func `showing personal info keeps the existing email and workspace title`() {
        let account = self.account(id: "a", email: "person@example.com", workspace: "Acme")
        #expect(self.label(account, ordinal: 1, hide: false) == account.menuDisplayName)
        #expect(self.label(account, ordinal: 1, hide: false).contains("person@example.com"))
    }

    @Test
    func `hiding personal info drops the email and keeps the workspace`() {
        let account = self.account(id: "a", email: "person@example.com", workspace: "Acme")
        let label = self.label(account, ordinal: 1, hide: true)
        #expect(label == "Account 1 · Acme")
        #expect(!label.contains("person@example.com"))
        #expect(!label.contains("@"))
    }

    @Test
    func `an account with no workspace falls back to an ordinal rather than a blank button`() {
        let account = self.account(id: "a", email: "person@example.com")
        let label = self.label(account, ordinal: 3, hide: true)
        #expect(label == "Account 3")
        #expect(!label.isEmpty)
        #expect(!label.contains("@"))
        // A blank-workspace string must not slip through as an empty title either.
        let blank = self.account(id: "b", email: "other@example.com", workspace: "   ")
        #expect(self.label(blank, ordinal: 2, hide: true) == "Account 2")
    }

    @Test
    func `redacted ordinals follow stable identity, not display order`() {
        let accounts = [
            self.account(id: "ccc", email: "c@example.com"),
            self.account(id: "aaa", email: "a@example.com"),
            self.account(id: "bbb", email: "b@example.com"),
        ]
        let ordinals = CodexAccountSwitcherLabeling.ordinals(for: accounts)
        #expect(ordinals == ["aaa": 1, "bbb": 2, "ccc": 3])
        // Reordering the display list must not renumber the accounts.
        #expect(CodexAccountSwitcherLabeling.ordinals(for: Array(accounts.reversed())) == ordinals)
    }

    @Test
    func `redacted labels stay distinct when accounts share a workspace (#3282)`() {
        // Two accounts, different emails, same Business workspace. Dropping the email must not
        // collapse them onto one name: #3282 requires every selection surface to distinguish
        // accounts before credentials are switched.
        let accounts = [
            self.account(id: "aaa", email: "one@example.com", workspace: "Odaseva"),
            self.account(id: "bbb", email: "two@example.com", workspace: "Odaseva"),
        ]
        let labels = CodexAccountSwitcherLabeling.labels(for: accounts, hidePersonalInfo: true)
        #expect(labels["aaa"] != labels["bbb"])
        #expect(labels["aaa"] == "Account 1 · Odaseva")
        #expect(labels["bbb"] == "Account 2 · Odaseva")
        for label in labels.values {
            #expect(!label.contains("@"))
        }
    }

    @Test
    func `same-email accounts in different workspaces keep their workspace names`() {
        // The #3282 case itself: one email, two workspaces.
        let accounts = [
            self.account(id: "aaa", email: "same@example.com", workspace: "Workspace A"),
            self.account(id: "bbb", email: "same@example.com", workspace: "Workspace B"),
        ]
        let labels = CodexAccountSwitcherLabeling.labels(for: accounts, hidePersonalInfo: true)
        #expect(labels["aaa"] == "Account 1 · Workspace A")
        #expect(labels["bbb"] == "Account 2 · Workspace B")
    }

    @Test
    func `showing personal info leaves labels untouched even when they collide`() {
        let accounts = [
            self.account(id: "aaa", email: "same@example.com"),
            self.account(id: "bbb", email: "same@example.com"),
        ]
        let labels = CodexAccountSwitcherLabeling.labels(for: accounts, hidePersonalInfo: false)
        // Disambiguating unredacted labels is #3282's own concern (displayDiscriminator), not this
        // redaction rule's; it must not start rewriting them.
        #expect(labels["aaa"] == accounts[0].menuDisplayName)
        #expect(labels["bbb"] == accounts[1].menuDisplayName)
    }

    @Test
    func `no rendered switcher title or tooltip leaks an email when hiding personal info`() {
        let accounts = [
            self.account(id: "a", email: "person@example.com", workspace: "Acme"),
            self.account(id: "b", email: "other@example.com"),
        ]
        let view = CodexAccountSwitcherView(
            accounts: accounts,
            selectedAccountID: "a",
            width: 320,
            hidePersonalInfo: true,
            onSelect: { _ in })
        view.layoutSubtreeIfNeeded()
        for title in view._test_buttonTitles() + view._test_buttonToolTips().compactMap(\.self) {
            #expect(!title.contains("@"), "leaked: \(title)")
            #expect(!title.isEmpty)
        }
    }

    @Test
    func `workspace emails and generated-looking labels stay private and distinct`() {
        let accounts = [
            self.account(id: "a", email: "first@example.com", workspace: "Acme"),
            self.account(id: "b", email: "second@example.com", workspace: "Acme"),
            self.account(id: "c", email: "third@example.com", workspace: "Acme · Account 1"),
            self.account(id: "d", email: "fourth@example.com", workspace: "Team fourth@example.com"),
        ]
        let labels = CodexAccountSwitcherLabeling.labels(for: accounts, hidePersonalInfo: true)
        #expect(Set(labels.values).count == accounts.count)
        #expect(labels.values.allSatisfy { !$0.contains("@") })
        let view = CodexAccountSwitcherView(
            accounts: accounts, selectedAccountID: "a", width: 150, hidePersonalInfo: true, onSelect: { _ in })
        view.layoutSubtreeIfNeeded()
        #expect(Set(view._test_buttonTitles()).count == accounts.count)
        #expect((view._test_buttonTitles() + view._test_buttonToolTips().compactMap(\.self))
            .allSatisfy { !$0.contains("@") })
    }

    @Test
    func `unrecognized email-like workspace text falls back to the account number`() {
        let account = self.account(id: "a", email: "person@example.com", workspace: "用户@example.com")
        #expect(self.label(account, ordinal: 1, hide: true) == "Account 1")
    }
}
