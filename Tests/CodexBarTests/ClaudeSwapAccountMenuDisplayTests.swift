import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct ClaudeSwapAccountMenuDisplayTests {
    private func account(_ slot: String, active: Bool = false, canActivate: Bool = true)
        -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: slot),
            provider: .claude,
            displayLabel: "person\(slot)@example.com",
            isActive: active,
            canActivate: canActivate && !active,
            snapshot: nil,
            error: nil,
            sourceLabel: "claude-swap")
    }

    private func display(
        _ accounts: [ProviderAccountUsageSnapshot],
        layout: MultiAccountMenuLayout = .segmented,
        switching: ProviderAccountIdentity? = nil,
        error: ProviderAccountIdentity? = nil) -> ClaudeSwapAccountMenuDisplay
    {
        ClaudeSwapAccountMenuDisplay(
            accounts: accounts, layout: layout, switchingAccountID: switching, errorAccountID: error)
    }

    @Test
    func `segmented preference selects the active stable slot after adapter reordering`() {
        let first = self.account("7")
        let active = self.account("2", active: true)
        for accounts in [[first, active], [active, first]] {
            let display = self.display(accounts)
            #expect(display.showsSwitcher)
            #expect(display.displayedAccount?.id == active.id)
        }
        #expect(!self.display([active]).showsSwitcher)
        #expect(!self.display([first, active], layout: .stacked).showsSwitcher)
        #expect(self.display([first, self.account("9")]).displayedAccount == nil)
        #expect(self.display([self.account("9"), first]).displayedAccount == nil)
    }

    @Test
    func `pending and failed activation retain the requested account details`() {
        let active = self.account("2", active: true)
        let target = self.account("7")
        let removed = self.account("9")
        #expect(self.display([active, target], switching: target.id).displayedAccount?.id == target.id)
        #expect(self.display([active, target], error: target.id).displayedAccount?.id == target.id)
        #expect(self.display([active, target], error: removed.id).displayedAccount?.id == active.id)
        #expect(self.display([]).displayedAccount == nil)
        var inspected = self.display([active, target], error: target.id)
        inspected.inspectedAccountID = active.id
        #expect(inspected.displayedAccount?.id == active.id)
    }

    @Test
    func `redaction uses stable slot ordinals instead of labels or list positions`() {
        let account = self.account("7")
        #expect(ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: true) == "Account 7")
        #expect(ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: false) == account.displayLabel)
    }

    @Test
    func `switcher permits inspection and serializes repeated activation selection`() {
        let active = self.account("2", active: true)
        let unavailable = self.account("3", canActivate: false)
        let target = self.account("7")
        var selected: [ProviderAccountIdentity] = []
        let view = ClaudeSwapAccountSwitcherView(
            display: self.display([target, unavailable, active]),
            hidePersonalInfo: true,
            width: 320,
            onSelect: { selected.append($0) })
        view._test_select(unavailable.id)
        view._test_select(active.id)
        #expect(selected == [unavailable.id, active.id])
        view._test_select(target.id)
        view._test_select(target.id)
        #expect(selected == [unavailable.id, active.id, target.id])
        #expect(view.fittingSize.height == 26)
        let wrapped = ClaudeSwapAccountSwitcherView(
            display: self.display([active, target, unavailable, self.account("8")]),
            hidePersonalInfo: true,
            width: 320,
            onSelect: { _ in })
        #expect(wrapped.fittingSize.height == 56)
    }
}
