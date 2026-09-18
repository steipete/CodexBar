import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func resolvingCurrentCopilotAllowance(
        in snapshot: UsageSnapshot,
        provider: UsageProvider,
        account: ProviderTokenAccount? = nil) -> UsageSnapshot
    {
        guard provider == .copilot else { return snapshot }
        let override: TokenAccountOverride?
        if let account {
            guard let current = self.uniqueTokenAccount(provider: provider, accountID: account.id)
            else { return snapshot }
            override = TokenAccountOverride(provider: provider, account: current)
        } else {
            override = nil
        }
        let entitlement = self.settings.copilotSettingsSnapshot(tokenOverride: override).seatCreditEntitlement
        return snapshot.updatingCopilotSeatCreditEntitlement(entitlement) ?? snapshot
    }

    func resolvingCurrentCopilotAllowance(
        in cached: TokenAccountUsageSnapshot,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> TokenAccountUsageSnapshot
    {
        guard provider == .copilot, let snapshot = cached.snapshot else { return cached }
        return TokenAccountUsageSnapshot(
            account: cached.account,
            snapshot: self.resolvingCurrentCopilotAllowance(in: snapshot, provider: provider, account: account),
            error: cached.error,
            sourceLabel: cached.sourceLabel,
            cacheKey: cached.cacheKey)
    }

    /// Capture a validated cache before saving: the allowance is part of the account cache key.
    func setCopilotSeatCreditEntitlement(_ rawValue: String) {
        let previousAccount = self.settings.effectiveSelectedTokenAccount(for: .copilot)
        let cached = previousAccount.flatMap { account in
            self.validTokenAccountSnapshots(
                provider: .copilot,
                accounts: [account]).first
        }
        self.settings.copilotEffectiveSeatCreditEntitlementRaw = rawValue
        let entitlement = self.settings.copilotSettingsSnapshot(tokenOverride: nil).seatCreditEntitlement
        guard let previousAccount else {
            self.updateCopilotSeatCreditEntitlement(entitlement)
            return
        }
        if let cached,
           let account = self.settings.effectiveSelectedTokenAccount(for: .copilot),
           self.uniqueTokenAccount(
               provider: .copilot,
               accountID: account.id) != nil
        {
            let previousAllowanceAccount = ProviderTokenAccount(
                id: account.id,
                label: account.label,
                token: account.token,
                addedAt: account.addedAt,
                lastUsed: account.lastUsed,
                externalIdentifier: account.externalIdentifier,
                usageScope: account.usageScope,
                organizationID: account.organizationID,
                workspaceID: account.workspaceID,
                seatCreditEntitlement: previousAccount.seatCreditEntitlement)
            if cached.cacheKey == self.tokenAccountSnapshotCacheKey(
                provider: .copilot,
                account: previousAllowanceAccount),
                let index = self.accountSnapshots[.copilot]?.firstIndex(where: { $0.id == account.id })
            {
                self.accountSnapshots[.copilot]?[index] = TokenAccountUsageSnapshot(
                    account: account,
                    snapshot: cached.snapshot?.updatingCopilotSeatCreditEntitlement(entitlement) ?? cached.snapshot,
                    error: cached.error,
                    sourceLabel: cached.sourceLabel,
                    cacheKey: self.tokenAccountSnapshotCacheKey(
                        provider: .copilot,
                        account: account))
            }
        }
        self.reconcileSelectedTokenAccountSnapshotBeforeRefresh(
            provider: .copilot,
            accounts: self.settings.tokenAccounts(for: .copilot))
    }

    func updateCopilotSeatCreditEntitlement(_ entitlement: Double?) {
        if let snapshot = self.snapshots[.copilot],
           let updated = snapshot.updatingCopilotSeatCreditEntitlement(entitlement)
        {
            self.snapshots[.copilot] = updated
        }
        if let resetSnapshot = self.lastKnownResetSnapshots[.copilot],
           let updated = resetSnapshot.updatingCopilotSeatCreditEntitlement(entitlement)
        {
            self.lastKnownResetSnapshots[.copilot] = updated
        }
    }

    func clearCopilotDefaultSeatCreditEntitlement() {
        let accounts = self.settings.tokenAccounts(for: .copilot)
        let cached = self.validTokenAccountSnapshots(provider: .copilot, accounts: accounts)
        self.settings.copilotSeatCreditEntitlementRaw = ""
        for entry in cached where entry.account.sanitizedSeatCreditEntitlement == nil {
            guard let index = self.accountSnapshots[.copilot]?.firstIndex(where: { $0.id == entry.id })
            else { continue }
            self.accountSnapshots[.copilot]?[index] = TokenAccountUsageSnapshot(
                account: entry.account,
                snapshot: entry.snapshot?.updatingCopilotSeatCreditEntitlement(nil) ?? entry.snapshot,
                error: entry.error,
                sourceLabel: entry.sourceLabel,
                cacheKey: entry.cacheKey)
        }
        guard let selected = self.settings.effectiveSelectedTokenAccount(for: .copilot) else {
            self.updateCopilotSeatCreditEntitlement(nil)
            return
        }
        if selected.sanitizedSeatCreditEntitlement == nil {
            self.reconcileSelectedTokenAccountSnapshotBeforeRefresh(provider: .copilot, accounts: accounts)
        }
    }
}

extension UsageSnapshot {
    /// Returns a copy with the seat credits row rebuilt for `entitlement`, or `nil` when nothing
    /// changed (no row, or a row that carries no numeric usage at all — the next refresh must
    /// rebuild it). The numerator comes from `row.progress.used`, falling back to the retained
    /// `row.usageValue` on text-only rows, never re-parsed from the display string. That fallback
    /// is what lets a cached text-only row grow a bar the moment an entitlement is entered, even
    /// when the follow-up refresh never lands (offline, token lost, 401).
    func updatingCopilotSeatCreditEntitlement(_ entitlement: Double?) -> UsageSnapshot? {
        if self.copilotMeteredZeroCredits {
            return self.updatingMeteredZeroCopilotEntitlement(entitlement)
        }
        guard self.details.lazy.flatMap(\.rows)
            .contains(where: {
                $0.id == CopilotCreditDetailRows.seatRowID && ($0.progress != nil || $0.usageValue != nil)
            })
        else { return nil }
        let details = self.details.map { section -> ProviderDetailSection in
            let rows = section.rows.map { row -> ProviderDetailSection.Row in
                guard row.id == CopilotCreditDetailRows.seatRowID, let used = row.progress?.used ?? row.usageValue
                else { return row }
                let value: String
                let progress: ProviderDetailSection.Row.Progress?
                if let entitlement {
                    guard let rebuilt = try? ProviderDetailSection.Row.Progress(
                        used: used,
                        total: entitlement)
                    else { return row }
                    value = "\(UsageFormatter.creditsNumberString(from: used)) / " +
                        UsageFormatter.creditsNumberString(from: entitlement)
                    progress = rebuilt
                } else {
                    value = UsageFormatter.creditsNumberString(from: used)
                    progress = nil
                }
                return (try? ProviderDetailSection.Row(
                    id: row.id,
                    label: row.label,
                    value: value,
                    secondaryValue: row.secondaryValue,
                    progress: progress,
                    usageValue: used)) ?? row
            }
            return (try? ProviderDetailSection(
                title: section.title,
                rows: rows,
                chart: section.chart)) ?? section
        }
        return self.with(details: details)
    }

    private func updatingMeteredZeroCopilotEntitlement(_ entitlement: Double?) -> UsageSnapshot? {
        let index = self.details.firstIndex { $0.rows.contains { $0.id == CopilotCreditDetailRows.seatRowID } } ?? 0
        var details = self.details.compactMap { section -> ProviderDetailSection? in
            let rows = section.rows.filter { $0.id != CopilotCreditDetailRows.seatRowID }
            guard rows.count != section.rows.count else { return section }
            guard !rows.isEmpty || section.chart != nil else { return nil }
            return try? ProviderDetailSection(title: section.title, rows: rows, chart: section.chart)
        }
        if let entitlement {
            guard details.count < ProviderDetailSection.maximumSectionsPerSnapshot,
                  let progress = try? ProviderDetailSection.Row.Progress(used: 0, total: entitlement),
                  let row = try? ProviderDetailSection.Row(
                      id: CopilotCreditDetailRows.seatRowID,
                      label: "Credits used",
                      value: "0 / " + UsageFormatter.creditsNumberString(from: entitlement),
                      secondaryValue: (self.primary?.resetsAt ?? self.secondary?.resetsAt)
                          .map { UsageFormatter.resetDescription(from: $0) },
                      progress: progress,
                      usageValue: 0),
                  let section = try? ProviderDetailSection(title: CopilotCreditDetailRows.sectionTitle, rows: [row])
            else { return nil }
            details.insert(section, at: min(index, details.count))
        }
        return self.with(details: details)
    }
}
