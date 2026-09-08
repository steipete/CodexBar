import CodexBarCore
import Foundation

struct ClaudeSwapAccountMenuDisplay {
    let accounts: [ProviderAccountUsageSnapshot]
    let layout: MultiAccountMenuLayout
    let switchingAccountID: ProviderAccountIdentity?
    let errorAccountID: ProviderAccountIdentity?
    var inspectedAccountID: ProviderAccountIdentity?

    var showsSwitcher: Bool {
        self.layout == .segmented && self.accounts.count > 1
    }

    var displayedAccount: ProviderAccountUsageSnapshot? {
        // Keep pending/failed activation details attached to the requested stable slot.
        for id in [self.switchingAccountID, self.inspectedAccountID, self.errorAccountID].compactMap(\.self) {
            if let account = self.accounts.first(where: { $0.id == id }) {
                return account
            }
        }
        return self.accounts.first(where: \.isActive)
    }

    static func label(for account: ProviderAccountUsageSnapshot, hidePersonalInfo: Bool) -> String {
        hidePersonalInfo
            ? String(format: L("Account %@"), account.id.opaqueID)
            : account.displayLabel
    }
}
