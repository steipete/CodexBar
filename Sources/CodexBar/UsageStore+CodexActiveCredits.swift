import CodexBarCore
import Foundation

extension UsageStore {
    /// Credits for the Codex account selected in the menu (tabs / Menu bar account).
    /// Primary (`~/.codex`) uses RPC/dashboard `credits`; add-on accounts use OAuth rows in `allAccountCredits`.
    func codexActiveMenuCredits() -> (snapshot: CreditsSnapshot?, error: String?, unlimited: Bool) {
        guard let data = self.settings.tokenAccountsData(for: .codex), !data.accounts.isEmpty else {
            return (self.credits, self.lastCreditsError, false)
        }
        if data.isDefaultActive {
            return (self.credits, self.lastCreditsError, false)
        }
        let index = data.clampedActiveIndex()
        guard index >= 0, index < data.accounts.count else {
            return (self.credits, self.lastCreditsError, false)
        }
        let account = data.accounts[index]
        let entries = self.allAccountCredits[.codex] ?? []
        let entry = entries.first { $0.id == account.id.uuidString }
        if let entry {
            let trimmedErr = entry.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedErr.isEmpty {
                return (nil, Self.shortCodexOAuthErrorMessage(trimmedErr), false)
            }
            if entry.isUnlimited {
                return (nil, nil, true)
            }
            if let bal = entry.creditsRemaining, bal > 0, bal.isFinite {
                return (
                    CreditsSnapshot(remaining: bal, events: [], updatedAt: entry.updatedAt),
                    nil,
                    false)
            }
            return (nil, nil, false)
        }
        if self.accountCostRefreshInFlight.contains(.codex) {
            return (nil, "Loading credits…", false)
        }
        return (nil, nil, false)
    }

    /// Remaining prepaid balance for the active Codex account (menu bar icon, switcher, widget).
    func codexActiveCreditsRemaining() -> Double? {
        let (snapshot, _, unlimited) = self.codexActiveMenuCredits()
        if unlimited { return nil }
        guard let remaining = snapshot?.remaining, remaining.isFinite, remaining > 0 else { return nil }
        return remaining
    }

    private static func shortCodexOAuthErrorMessage(_ error: String) -> String {
        if error.contains("not found") || error.contains("notFound") { return "Not signed in" }
        if error.localizedCaseInsensitiveContains("unauthorized") || error.contains("401") { return "Token expired" }
        return error
    }
}
