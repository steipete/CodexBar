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
           !self.claudeSwapAccountSnapshots.isEmpty
        {
            return self.claudeSwapAccountSnapshots.compactMap { account in
                // Slots can be reused. Bind the pin to the same opaque ownership guard as retained usage,
                // without persisting the adapter's email, organization, or display label.
                guard let owner = ClaudeSwapRetainedUsageStore.ownershipFingerprint(for: account) else { return nil }
                return self.widgetAccountEntry(
                    provider: .claude,
                    id: "claude/swap:\(account.id.opaqueID):\(owner)",
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
            return accounts.enumerated().compactMap { index, account in
                guard let id = Self.widgetCodexAccountID(account) else { return nil }
                let matches = self.codexAccountSnapshots.filter {
                    Self.widgetCodexAccountID($0.account) == id &&
                        Self.codexPriorSnapshotAccountMatches($0.account, account: account)
                }
                let snapshot = matches.count == 1 ? matches.first?.snapshot : nil
                return self.widgetAccountEntry(
                    provider: .codex,
                    id: id,
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

    static func widgetCodexAccountID(_ account: CodexVisibleAccount) -> String? {
        let identity: String
        if case let .profileHome(path) = account.selectionSource {
            guard let owner = Self.widgetCodexOwnerIdentity(account),
                  let path = CodexHomeScope.normalizedHomePath(path)
            else { return nil }
            identity = "profile\0\(path)\0\(owner)"
        } else if let storedID = account.storedAccountID {
            // A managed account keeps its identity when promoted to the live system account.
            identity = "managed\0\(storedID.uuidString.lowercased())"
        } else if case let .managedAccount(id) = account.selectionSource {
            identity = "managed\0\(id.uuidString.lowercased())"
        } else {
            guard let owner = Self.widgetCodexOwnerIdentity(account) else { return nil }
            identity = "system\0\(owner)"
        }
        // The menu's account.id changes when same-email siblings appear. Neither it nor rotating
        // credential fingerprints are identities for a persisted widget configuration.
        return "codex/visible:\(Self.widgetOpaqueAccountID(identity))"
    }

    private static func widgetCodexOwnerIdentity(_ account: CodexVisibleAccount) -> String? {
        guard let email = CodexIdentityResolver.normalizeEmail(account.email) else { return nil }
        if let workspace = ManagedCodexAccount.normalizeWorkspaceAccountID(account.workspaceAccountID) {
            return "workspace:\(CodexOpenAIWorkspaceIdentity.normalizeWorkspaceAccountID(workspace))\0email:\(email)"
        }
        return "email:\(email)"
    }

    func reconcileCodexWidgetAccountSnapshots(after error: Error? = nil) {
        guard self.settings.accountWidgetsEnabled, !self.shouldUseAmbientCodexPATForUsage() else {
            self.codexAccountSnapshots = []
            return
        }
        self.codexAccountSnapshots = Self.codexAccountSnapshots(
            self.codexAccountSnapshots,
            reconciledWith: self.settings.codexVisibleAccountProjection)
        if let error {
            self.codexAccountSnapshots.removeAll {
                !Self.shouldPreservePriorSnapshot(after: error, hadPriorData: $0.snapshot != nil)
            }
        }
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
