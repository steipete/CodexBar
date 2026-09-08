import CodexBarCore
import Foundation

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

    /// The segment to highlight as "showing details", independent of the active-account marker.
    var displayedAccountID: ProviderAccountIdentity? {
        self.displayedAccount?.id
    }

    static func label(for account: ProviderAccountUsageSnapshot, hidePersonalInfo: Bool) -> String {
        hidePersonalInfo
            ? String(format: L("Account %@"), account.id.opaqueID)
            : account.displayLabel
    }
}
