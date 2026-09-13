import AppKit
import CodexBarCore

/// A menu-only record of which claude-swap account the user asked to look at, scoped to the
/// adapter configuration it was made under. Viewing never activates a slot, so this state is
/// deliberately separate from the source-owned active account.
struct ClaudeSwapViewSelection: Equatable {
    let configurationKey: String
    let accountID: ProviderAccountIdentity
}

struct ClaudeSwapAccountMenuDisplay {
    let accounts: [ProviderAccountUsageSnapshot]
    let layout: MultiAccountMenuLayout
    let switchingAccountID: ProviderAccountIdentity?
    let errorAccountID: ProviderAccountIdentity?
    /// The account the user selected for viewing. Never implies activation.
    var viewedAccountID: ProviderAccountIdentity?

    var showsSwitcher: Bool {
        self.layout == .segmented && self.accounts.count > 1
    }

    /// The account whose card the segmented menu shows.
    ///
    /// An explicit view selection wins over a pending or failed activation so a later click is
    /// never overridden by an in-flight switch. Without a selection, pending/failed activation
    /// keeps its details attached to the requested stable slot. The source-owned active account
    /// is the last fallback; no active account is invented when the adapter reports none, and a
    /// slot that disappeared from the list falls through to that fallback.
    var displayedAccount: ProviderAccountUsageSnapshot? {
        for id in [self.viewedAccountID, self.switchingAccountID, self.errorAccountID].compactMap(\.self) {
            if let account = self.accounts.first(where: { $0.id == id }) {
                return account
            }
        }
        return self.accounts.first(where: \.isActive)
    }

    /// The segment to highlight as Selected, independent of the System marker.
    var displayedAccountID: ProviderAccountIdentity? {
        self.displayedAccount?.id
    }

    static func label(for account: ProviderAccountUsageSnapshot, hidePersonalInfo: Bool) -> String {
        hidePersonalInfo
            ? String(format: L("Account %@"), account.id.opaqueID)
            : account.displayLabel
    }

    static func cardContext(
        for account: ProviderAccountUsageSnapshot,
        planLabel: String?,
        adapterError: String?,
        switchError: String?) -> UsageMenuCardContext
    {
        .account(.init(
            snapshot: account.snapshot,
            error: ClaudeSwapAccountProjection.displayError(
                accountError: account.error,
                adapterError: adapterError,
                switchError: switchError),
            info: AccountInfo(email: account.displayLabel, plan: nil),
            plan: .label(planLabel),
            planEmphasis: account.isActive ? .active : .none,
            lastKnownUsageCapturedAt: account.usesLastKnownUsage ? account.snapshot?.updatedAt : nil,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel))
    }

    static func actionLabel(
        for account: ProviderAccountUsageSnapshot,
        switchingAccountID: ProviderAccountIdentity?,
        switchInFlight: Bool) -> String?
    {
        if account.isActive, !account.canActivate { return L("Active") }
        if switchingAccountID == account.id { return L("Loading…") }
        guard !switchInFlight, account.canActivate else { return nil }
        return account.isActive ? L("Re-authenticate") : L("Switch Account...")
    }

    /// Switcher segments keyed by claude-swap slot. The System marker follows the account claude-swap reports
    /// active; the fitted title keeps the slot readable when labels are long.
    static func segments(
        for accounts: [ProviderAccountUsageSnapshot],
        hidePersonalInfo: Bool) -> [AccountSwitcherSegment]
    {
        accounts.map { account in
            let label = self.label(for: account, hidePersonalInfo: hidePersonalInfo)
            return AccountSwitcherSegment(
                id: account.id.opaqueID,
                fullLabel: label,
                isSystem: account.isActive,
                title: { width, measure in
                    label.contains("@")
                        ? SwitcherTitleFitting.truncateMiddle(label, toFit: width, measure: measure)
                        : SwitcherTitleFitting.truncateTail(label, toFit: width, measure: measure)
                })
        }
    }

    @MainActor
    static func switcherView(
        display: ClaudeSwapAccountMenuDisplay,
        hidePersonalInfo: Bool,
        width: CGFloat,
        onSelect: @escaping (ProviderAccountIdentity) -> Void) -> AccountSegmentedSwitcherView
    {
        AccountSegmentedSwitcherView(
            segments: self.segments(for: display.accounts, hidePersonalInfo: hidePersonalInfo),
            // Never invent a selection: with no viewed, pending or active account nothing is highlighted.
            selectedID: display.displayedAccountID?.opaqueID,
            width: width,
            onSelect: { slot in
                guard let account = display.accounts.first(where: { $0.id.opaqueID == slot }) else { return }
                onSelect(account.id)
            })
    }
}
