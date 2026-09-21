import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct ClaudeSwapAccountMenuDisplayTests {
    private func account(_ slot: String, active: Bool = false, canActivate: Bool? = nil)
        -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: slot),
            provider: .claude,
            displayLabel: "person\(slot)@example.com",
            isActive: active,
            canActivate: canActivate ?? !active,
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
    func `chip help names activation only for inactive actionable accounts and respects privacy`() {
        let target = self.account("7")
        let active = self.account("2", active: true)
        let activeNeedingRepair = self.account("3", active: true, canActivate: true)
        let unavailable = self.account("9", canActivate: false)
        #expect(ClaudeSwapAccountMenuDisplay.chipHelp(for: target, hidePersonalInfo: true) ==
            L("Switch Claude Code to %@", "Account 7"))
        #expect(ClaudeSwapAccountMenuDisplay.chipHelp(for: target, hidePersonalInfo: false) ==
            L("Switch Claude Code to %@", target.displayLabel))
        for account in [active, activeNeedingRepair, unavailable] {
            #expect(!ClaudeSwapAccountMenuDisplay.activatesAccount(account))
            #expect(ClaudeSwapAccountMenuDisplay.chipHelp(for: account, hidePersonalInfo: true) ==
                L("Details for %@", "Account \(account.id.opaqueID)"))
        }
    }

    @Test(arguments: [ClaudeSwapSwitchPhase.activating, .reconciling])
    func `target progress survives an early adapter active marker`(phase: ClaudeSwapSwitchPhase) {
        let label = phase == .activating ? L("Switching account…") : L("Refreshing account status…")
        for target in [self.account("7"), self.account("7", active: true)] {
            #expect(ClaudeSwapAccountMenuDisplay.actionLabel(
                for: target,
                switchingAccountID: target.id,
                switchInFlight: true,
                switchPhase: phase) == label)
        }
        #expect(ClaudeSwapAccountMenuDisplay.actionLabel(
            for: self.account("9"),
            switchingAccountID: self.account("7").id,
            switchInFlight: true,
            switchPhase: phase) == nil)
    }

    @Test
    func `switcher permits inspection and serializes repeated activation selection`() {
        let active = self.account("2", active: true, canActivate: true)
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

    @Test
    func `three narrow chips retain their identity titles and expose privacy safe action labels`() throws {
        let accounts = [self.account("1", active: true), self.account("2"), self.account("3", canActivate: false)]
        let view = ClaudeSwapAccountSwitcherView(
            display: self.display(accounts),
            hidePersonalInfo: true,
            width: 280,
            onSelect: { _ in })
        let stack = try #require(view.subviews.first as? NSStackView)
        let row = try #require(stack.arrangedSubviews.first as? NSStackView)
        let buttons = row.arrangedSubviews.compactMap { $0 as? NSButton }
        #expect(buttons.map(\.title) == ["Account 1", "Account 2", "Account 3"])
        let help = [
            L("Details for %@", "Account 1"),
            L("Switch Claude Code to %@", "Account 2"),
            L("Details for %@", "Account 3"),
        ]
        #expect(buttons.map(\.toolTip) == help.map(Optional.some))
        #expect(buttons.map { $0.accessibilityLabel() } == help.map(Optional.some))
        #expect(buttons.map(\.state) == [.on, .off, .off])
        view._test_select(accounts[1].id)
        #expect(buttons.allSatisfy { !$0.isEnabled })
    }
}
