import AppKit
import CodexBarCore

/// The Codex account switcher row. A distinct type only so menu reuse and smart-update logic can recognize the
/// Codex switcher; all behavior lives in `AccountSegmentedSwitcherView`.
final class CodexAccountSwitcherView: AccountSegmentedSwitcherView {}

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

    static func segments(for accounts: [CodexVisibleAccount], hidePersonalInfo: Bool) -> [AccountSwitcherSegment] {
        let ordinals = self.ordinals(for: accounts)
        let labels = self.labels(for: accounts, hidePersonalInfo: hidePersonalInfo)
        return accounts.map { account in
            let ordinal = ordinals[account.id]
            let fullLabel = labels[account.id] ?? self.accountLabel(ordinal: ordinal)
            return AccountSwitcherSegment(
                id: account.id,
                fullLabel: fullLabel,
                isSystem: account.isLive,
                title: { width, measure in
                    hidePersonalInfo
                        ? self.privateTitle(fullLabel: fullLabel, ordinal: ordinal, width: width, measure: measure)
                        : self.fittedTitle(for: account, width: width, measure: measure)
                },
                minimumTitle: account.displayDiscriminator)
        }
    }

    @MainActor
    static func switcherView(
        accounts: [CodexVisibleAccount],
        selectedAccountID: String?,
        width: CGFloat,
        hidePersonalInfo: Bool = false,
        onSelect: @escaping (CodexVisibleAccount) -> Void) -> CodexAccountSwitcherView
    {
        CodexAccountSwitcherView(
            segments: self.segments(for: accounts, hidePersonalInfo: hidePersonalInfo),
            // Codex always highlights an account: it defaults to the first when none is selected.
            selectedID: selectedAccountID ?? accounts.first?.id,
            width: width,
            onSelect: { id in
                guard let account = accounts.first(where: { $0.id == id }) else { return }
                onSelect(account)
            })
    }

    private static func privateTitle(
        fullLabel: String,
        ordinal: Int?,
        width: CGFloat,
        measure: (String) -> CGFloat) -> String
    {
        if measure(fullLabel) <= width { return fullLabel }
        let short = self.accountLabel(ordinal: ordinal)
        return measure(short) <= width ? short : String(ordinal ?? 1)
    }

    private static func fittedTitle(
        for account: CodexVisibleAccount,
        width: CGFloat,
        measure: (String) -> CGFloat) -> String
    {
        if measure(account.menuDisplayName) <= width {
            return account.menuDisplayName
        }

        if let discriminator = account.displayDiscriminator {
            let suffix = "|\(discriminator)"
            let emailWidth = max(0, width - measure(suffix))
            guard emailWidth > measure("…") else { return discriminator }
            return SwitcherTitleFitting.truncateMiddle(account.email, toFit: emailWidth, measure: measure) + suffix
        }

        guard let workspace = account.menuWorkspaceLabel else {
            return SwitcherTitleFitting.truncateMiddle(account.email, toFit: width, measure: measure)
        }

        let separator = "|"
        let contentWidth = max(24, width - measure(separator))
        let minimumEmailWidth = min(contentWidth * 0.45, max(18, contentWidth * 0.3))
        let minimumWorkspaceWidth = min(contentWidth * 0.4, max(18, contentWidth * 0.25))
        var emailWidth = max(minimumEmailWidth, contentWidth * 0.58)
        var workspaceWidth = max(minimumWorkspaceWidth, contentWidth - emailWidth)

        func email() -> String {
            SwitcherTitleFitting.truncateMiddle(account.email, toFit: emailWidth, measure: measure)
        }

        func workspaceText() -> String {
            SwitcherTitleFitting.truncateTail(workspace, toFit: workspaceWidth, measure: measure)
        }

        var title = email() + separator + workspaceText()
        var attempts = 0
        while measure(title) > width, attempts < 16 {
            if measure(email()) >= measure(workspaceText()), emailWidth > minimumEmailWidth {
                emailWidth = max(minimumEmailWidth, emailWidth - 6)
            } else if workspaceWidth > minimumWorkspaceWidth {
                workspaceWidth = max(minimumWorkspaceWidth, workspaceWidth - 6)
            } else {
                break
            }
            title = email() + separator + workspaceText()
            attempts += 1
        }
        return title
    }
}
