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
        PersonalInfoRedactor.redactAccountLabel(
            account.displayLabel,
            isEnabled: hidePersonalInfo,
            ordinal: self.privacyOrdinal(for: account))
    }

    static func privacyOrdinal(for account: ProviderAccountUsageSnapshot) -> PersonalInfoRedactor.AccountOrdinal? {
        guard account.provider == .claude,
              account.id.source == ClaudeSwapAccountProjection.sourceName,
              let number = Int(account.id.opaqueID)
        else { return nil }
        return PersonalInfoRedactor.AccountOrdinal(number)
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
            privacyOrdinal: self.privacyOrdinal(for: account),
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
}
