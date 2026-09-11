import CodexBarCore
import Foundation

enum CodexAccountSwitcherLabeling {
    static func ordinals(for accounts: [CodexVisibleAccount]) -> [String: Int] {
        var ordinals: [String: Int] = [:]
        for (index, id) in accounts.map(\.id).sorted().enumerated() {
            ordinals[id] = index + 1
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
