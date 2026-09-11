import CodexBarCore
import Foundation

enum CodexAccountSwitcherLabeling {
    static func ordinals(for accounts: [CodexVisibleAccount]) -> [String: Int] {
        // The visible ID changes when a managed account becomes live; its persisted slot ID does not.
        let ordered = accounts.sorted { lhs, rhs in
            let left = lhs.storedAccountID?.uuidString ?? lhs.id
            let right = rhs.storedAccountID?.uuidString ?? rhs.id
            return left == right ? lhs.id < rhs.id : left < right
        }
        var ordinals: [String: Int] = [:]
        for (index, account) in ordered.enumerated() {
            ordinals[account.id] = index + 1
        }
        return ordinals
    }

    static func labels(for accounts: [CodexVisibleAccount], hidePersonalInfo: Bool) -> [String: String] {
        let ordinals = self.ordinals(for: accounts)
        return accounts.reduce(into: [:]) { labels, account in
            labels[account.id] = self.label(
                for: account, ordinal: ordinals[account.id], hidePersonalInfo: hidePersonalInfo)
        }
    }

    static func accountLabel(ordinal: Int?) -> String {
        L("Account %@", String(ordinal ?? 1))
    }

    static func label(for account: CodexVisibleAccount, ordinal: Int?, hidePersonalInfo: Bool) -> String {
        guard hidePersonalInfo else { return account.menuDisplayName }
        let number = self.accountLabel(ordinal: ordinal)
        guard let workspace = PersonalInfoRedactor.redactEmails(in: account.menuWorkspaceLabel, isEnabled: true),
              !workspace.isEmpty, !workspace.contains("@")
        else { return number }
        // A number on every private label also prevents collisions with user-supplied workspace names.
        return "\(number) · \(workspace)"
    }
}
