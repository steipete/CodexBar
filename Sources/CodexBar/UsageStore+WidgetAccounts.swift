import CodexBarCore
import CryptoKit
import Foundation

extension UsageStore {
    func makeWidgetAccountEntries(now: Date) -> [WidgetSnapshot.AccountEntry] {
        guard self.settings.accountWidgetsEnabled else { return [] }
        return self.enabledProviders().compactMap(\.firstPartyProvider).flatMap { provider in
            self.widgetAccounts(for: provider, now: now)
        }
    }

    private func widgetAccounts(for provider: UsageProvider, now: Date) -> [WidgetSnapshot.AccountEntry] {
        if provider == .claude, self.settings.claudeSwapEnabled,
           ClaudeSwapMenuPrecedence.prefersClaudeSwap(
               provider: .claude,
               accountCount: self.claudeSwapAccountSnapshots.count,
               showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        {
            return self.claudeSwapAccountSnapshots.map { account in
                // The adapter's display identity must not be persisted. Slots are its durable identity.
                self.widgetAccountEntry(
                    provider: .claude,
                    id: "claude/swap:\(account.id.opaqueID)",
                    label: "Account \(account.id.opaqueID)",
                    snapshot: account.snapshot,
                    now: now)
            }
        }
        if provider == .codex {
            // Use the reconciled visible projection to drop removed accounts and retain unavailable ones.
            let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay
            let accounts = self.limitedCodexVisibleAccounts(
                projection?.visibleAccounts ?? [],
                snapshots: self.codexAccountSnapshots,
                activeVisibleAccountID: projection?.activeVisibleAccountID)
            return accounts.enumerated().map { index, account in
                let cached = self.codexAccountSnapshots.first {
                    $0.id == account.id && Self.codexPriorSnapshotAccountMatches($0.account, account: account)
                }
                let snapshot = cached?.snapshot
                return self.widgetAccountEntry(
                    provider: .codex,
                    id: "codex/visible:\(Self.widgetOpaqueAccountID(account.id))",
                    label: self.settings.hidePersonalInfo ? "Account \(index + 1)" : account.menuDisplayName,
                    snapshot: snapshot,
                    now: now)
            }
        }
        guard self.settings.effectiveSelectedTokenAccount(for: provider) != nil else { return [] }
        let accounts = self.settings.tokenAccounts(for: provider)
        let snapshots = self.validTokenAccountSnapshots(provider: provider, accounts: accounts)
        return self.limitedTokenAccounts(
            accounts, selected: self.settings.effectiveSelectedTokenAccount(for: provider))
            .enumerated().map { index, account in
                self.widgetAccountEntry(
                    provider: provider,
                    id: "\(provider.rawValue)/token:\(account.id.uuidString)",
                    label: self.settings.hidePersonalInfo ? "Account \(index + 1)" : account.displayName,
                    snapshot: snapshots.first { $0.id == account.id }?.snapshot,
                    now: now)
            }
    }

    static func widgetOpaqueAccountID(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func widgetAccountEntry(
        provider: UsageProvider,
        id: String,
        label: String,
        snapshot: UsageSnapshot?,
        now: Date) -> WidgetSnapshot.AccountEntry
    {
        let usage = snapshot.map { snapshot in
            // Only account-owned quota data is available here. Provider-wide cost scans, dashboard
            // extras and history must never be copied into another account's widget.
            WidgetSnapshot.ProviderEntry(
                provider: provider,
                updatedAt: snapshot.updatedAt,
                primary: snapshot.primary,
                secondary: snapshot.secondary,
                tertiary: snapshot.tertiary,
                usageRows: self.widgetUsageRows(provider: provider, snapshot: snapshot, now: now),
                creditsRemaining: nil,
                codeReviewRemainingPercent: nil,
                tokenUsage: nil,
                dailyUsage: [],
                accountLabel: label)
        }
        return WidgetSnapshot.AccountEntry(id: id, provider: provider.instanceID, label: label, usage: usage)
    }
}
