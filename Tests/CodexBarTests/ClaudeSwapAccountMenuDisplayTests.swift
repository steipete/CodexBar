import AppKit
import CodexBarCore
import Foundation
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
        error: ProviderAccountIdentity? = nil,
        viewed: ProviderAccountIdentity? = nil) -> ClaudeSwapAccountMenuDisplay
    {
        ClaudeSwapAccountMenuDisplay(
            accounts: accounts,
            layout: layout,
            switchingAccountID: switching,
            errorAccountID: error,
            viewedAccountID: viewed)
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
    func `a view selection survives reordering and outranks pending or failed activation`() {
        let active = self.account("2", active: true)
        let target = self.account("7")
        for accounts in [[active, target], [target, active]] {
            #expect(self.display(accounts, viewed: target.id).displayedAccount?.id == target.id)
            #expect(
                self.display(accounts, switching: active.id, error: active.id, viewed: target.id)
                    .displayedAccount?.id == target.id)
        }
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
    }

    @Test
    func `a removed viewed slot falls back to the active account without inventing one`() {
        let active = self.account("2", active: true)
        let removed = self.account("9")
        #expect(self.display([active], viewed: removed.id).displayedAccount?.id == active.id)
        #expect(self.display([self.account("7")], viewed: removed.id).displayedAccount == nil)
        #expect(self.display([], viewed: removed.id).displayedAccount == nil)
    }

    @Test
    func `redaction uses stable slot ordinals instead of labels or list positions`() {
        let account = self.account("7")
        #expect(ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: true) == "Account 7")
        #expect(ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: false) == account.displayLabel)
    }

    @Test
    func `segment descriptions separate the source-owned active marker from the viewed segment`() {
        let describe = ClaudeSwapAccountSwitcherView.accessibilityDescription
        #expect(describe("Account 7", false, false) == "Account 7")
        #expect(describe("Account 2", true, false) == "Account 2 — Active")
        #expect(describe("Account 7", false, true) == "Account 7 — Showing details")
        #expect(describe("Account 2", true, true) == "Account 2 — Active — Showing details")
    }

    @Test
    func `switcher reports every selection without gating on availability or pending switches`() {
        let active = self.account("2", active: true)
        let unavailable = self.account("3", canActivate: false)
        let target = self.account("7")
        var selected: [ProviderAccountIdentity] = []
        let view = ClaudeSwapAccountSwitcherView(
            display: self.display([target, unavailable, active], switching: target.id),
            hidePersonalInfo: true,
            width: 320,
            onSelect: { selected.append($0) })
        view._test_select(unavailable.id)
        view._test_select(active.id)
        view._test_select(target.id)
        view._test_select(target.id)
        #expect(selected == [unavailable.id, active.id, target.id, target.id])
        // A pending switch with no view selection keeps the highlight on the requested slot,
        // while the active marker stays on the account claude-swap reports as active.
        #expect(view._test_selectedTitles == ["Account 7"])
        #expect(view._test_titles.contains("\(ClaudeSwapAccountSwitcherView.activeMarker) Account 2"))
        #expect(view.fittingSize.height == 26)
        let wrapped = ClaudeSwapAccountSwitcherView(
            display: self.display([active, target, unavailable, self.account("8")]),
            hidePersonalInfo: true,
            width: 320,
            onSelect: { _ in })
        #expect(wrapped.fittingSize.height == 56)
    }

    @Test
    func `the highlighted segment tracks the viewed account, not the active one`() {
        let active = self.account("2", active: true)
        let target = self.account("7")
        let viewingInactive = ClaudeSwapAccountSwitcherView(
            display: self.display([active, target], viewed: target.id),
            hidePersonalInfo: true,
            width: 320,
            onSelect: { _ in })
        #expect(viewingInactive._test_selectedTitles == ["Account 7"])
        #expect(viewingInactive._test_titles == [
            "\(ClaudeSwapAccountSwitcherView.activeMarker) Account 2",
            "Account 7",
        ])
    }
}

/// Opt-in synthetic render of the segmented claude-swap switcher. Set
/// `CODEXBAR_CLAUDE_SWAP_SWITCHER_PROOF_PATH` to write a PNG showing the viewed segment highlighted
/// independently of claude-swap's own active-account marker. Uses synthetic accounts only.
@MainActor
struct ClaudeSwapAccountSwitcherRenderProofTests {
    @Test
    func `render synthetic view-only account switcher`() throws {
        guard let output = ProcessInfo.processInfo
            .environment["CODEXBAR_CLAUDE_SWAP_SWITCHER_PROOF_PATH"] else { return }
        let accounts = [
            Self.account("1", active: true),
            Self.account("2"),
            Self.account("3", canActivate: false),
        ]
        let view = ClaudeSwapAccountSwitcherView(
            display: ClaudeSwapAccountMenuDisplay(
                accounts: accounts,
                layout: .segmented,
                switchingAccountID: nil,
                errorAccountID: nil,
                viewedAccountID: accounts[1].id),
            hidePersonalInfo: true,
            width: 380,
            onSelect: { _ in })

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 110))
        container.appearance = NSAppearance(named: .aqua)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        let title = NSTextField(labelWithString: "Viewing Account 2 · Account 1 is active")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: 20, y: 70, width: 380, height: 20)
        let detail = NSTextField(labelWithString: "Filled = viewed · ● = source-owned active account")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 20, y: 50, width: 380, height: 18)
        view.frame = NSRect(x: 20, y: 14, width: 380, height: 26)
        container.addSubview(title)
        container.addSubview(detail)
        container.addSubview(view)
        container.updateConstraintsForSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 840,
            pixelsHigh: 220,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        bitmap.size = container.bounds.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        container.displayIgnoringOpacity(container.bounds, in: context)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        print("[claude-swap-switcher-proof] titles=\(view._test_titles) selected=\(view._test_selectedTitles)")
    }

    private static func account(_ slot: String, active: Bool = false, canActivate: Bool = true)
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
}
