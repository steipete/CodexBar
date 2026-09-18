import CodexBarCore
import Foundation

struct GrokAccountUsageSnapshot: Identifiable {
    let id: String
    let account: GrokVisibleAccount
    let snapshot: UsageSnapshot?
    let error: String?
    let sourceLabel: String?

    init(
        account: GrokVisibleAccount,
        snapshot: UsageSnapshot?,
        error: String?,
        sourceLabel: String?)
    {
        self.id = account.id
        self.account = account
        self.snapshot = snapshot
        self.error = error
        self.sourceLabel = sourceLabel
    }
}

struct GrokAccountMenuDisplay: Equatable {
    let accounts: [GrokVisibleAccount]
    let snapshots: [GrokAccountUsageSnapshot]
    let activeVisibleAccountID: String?
    let layout: MultiAccountMenuLayout

    var showAll: Bool {
        self.layout == .stacked
    }

    var showSwitcher: Bool {
        self.layout == .segmented
    }

    static func == (lhs: GrokAccountMenuDisplay, rhs: GrokAccountMenuDisplay) -> Bool {
        lhs.accounts == rhs.accounts &&
            lhs.activeVisibleAccountID == rhs.activeVisibleAccountID &&
            lhs.layout == rhs.layout &&
            lhs.snapshots.map(\.id) == rhs.snapshots.map(\.id) &&
            lhs.snapshots.map(\.error) == rhs.snapshots.map(\.error) &&
            lhs.snapshots.map(\.sourceLabel) == rhs.snapshots.map(\.sourceLabel)
    }
}
