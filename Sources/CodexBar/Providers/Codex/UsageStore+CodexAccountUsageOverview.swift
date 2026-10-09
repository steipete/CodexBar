import CodexBarCore
import Foundation

extension UsageStore {
    func codexAccountUsageOverview(
        onRefresh: @escaping (Set<String>) -> Void) -> ProviderAccountUsageOverview?
    {
        // PAT has one ambient owner and cannot be attributed to the visible OAuth accounts.
        guard !self.shouldUseAmbientCodexPATForUsage() else { return nil }
        // Refresh failures belong to the current auth file, which can outlive its saved metadata fingerprint.
        let projection = self.codexVisibleAccountProjectionWithCurrentManagedAuth()
        let accounts = projection.visibleAccounts
        guard accounts.count > 1 else { return nil }
        let labels = CodexAccountSwitcherLabeling.labels(
            for: accounts, hidePersonalInfo: self.settings.hidePersonalInfo)
        let ordinals = CodexAccountSwitcherLabeling.ordinals(for: accounts)
        let records = Self.codexAccountSnapshots(self.codexAccountSnapshots, reconciledWith: projection)
        let rows = accounts.map { account in
            let matches = records.filter { $0.id == account.id }
            let record = matches.count == 1 ? matches.first : nil
            let sourceLabel = PersonalInfoRedactor.redactEmails(
                in: record?.sourceLabel, isEnabled: self.settings.hidePersonalInfo)
            let isFollowed = account.id == projection.activeVisibleAccountID
            let ownsLiveUsage = isFollowed && self.lastCodexUsagePublicationGuard.map {
                Self.codexScopedRefreshGuardsMatchAccount($0, Self.codexScopedRefreshGuard(for: account))
            } == true
            let followedError = ownsLiveUsage ? self.userFacingError(for: .codex) : nil
            let error = PersonalInfoRedactor.redactEmails(
                in: followedError ?? CodexUIErrorMapper.userFacingMessage(record?.error),
                isEnabled: self.settings.hidePersonalInfo)
            var model = UsageMenuCardView.Model.make(self.menuCardInput(for: .codex, context: .settingsAccount(.init(
                snapshot: record?.snapshot,
                error: error,
                info: AccountInfo(email: account.email, plan: nil),
                privacyOrdinal: ordinals[account.id].flatMap { PersonalInfoRedactor.AccountOrdinal($0) },
                sourceLabel: sourceLabel,
                credits: record?.credits))))
            if ownsLiveUsage {
                // Keep authorized dashboard extras on their owner; sibling cards never read live adjuncts.
                let liveModel = UsageMenuCardView.Model.make(self.menuCardInput(for: .codex, context: .settings))
                model.metrics += liveModel.metrics.filter { $0.id == "code-review" }
            }
            return ProviderAccountUsageOverview.Row(
                id: account.id,
                title: labels[account.id] ?? account.menuDisplayName,
                isFollowed: isFollowed,
                isSystem: account.id == projection.liveVisibleAccountID,
                model: model.applyingUsageItemVisibility(hiddenItemIDs: self.settings.hiddenUsageItemIDs(for: .codex)),
                usageItems: model.usageItemDescriptors,
                updatedAt: record?.snapshot?.updatedAt,
                sourceLabel: sourceLabel,
                error: error,
                isRefreshing: self.codexSettingsRefreshingAccountIDs.contains(account.id))
        }
        return ProviderAccountUsageOverview(
            rows: rows,
            refreshLimit: Self.tokenAccountMenuSnapshotLimit,
            canRefresh: self.isEnabled(.codex) && !self.refreshingProviders.contains(.codex),
            onRefresh: onRefresh)
    }

    func refreshCodexAccountsForSettings(_ accountIDs: Set<String>, allowDisabled: Bool = false) async {
        guard !accountIDs.isEmpty, !self.shouldUseAmbientCodexPATForUsage(),
              self.codexSettingsRefreshingAccountIDs.isEmpty,
              allowDisabled || self.isEnabled(.codex)
        else { return }
        let projection = self.freshCodexVisibleAccountProjectionForAccountRefresh()
        var remaining = projection.visibleAccounts.filter { accountIDs.contains($0.id) }
        guard !remaining.isEmpty else { return }
        let configRevision = self.settings.providerConfigRevision(for: .codex)
        self.codexSettingsRefreshingAccountIDs = Set(remaining.map(\.id))
        defer { self.codexSettingsRefreshingAccountIDs = [] }
        while !remaining.isEmpty, !Task.isCancelled,
              self.settings.providerConfigRevision(for: .codex) == configRevision,
              allowDisabled || self.isEnabled(.codex)
        {
            let batch = self.limitedCodexVisibleAccounts(
                remaining,
                snapshots: self.codexAccountSnapshots,
                activeVisibleAccountID: projection.activeVisibleAccountID)
            let batchIDs = Set(batch.map(\.id))
            await self.refreshProvider(.codex, allowDisabled: allowDisabled, codexAccountIDs: batchIDs)
            remaining.removeAll { batchIDs.contains($0.id) }
            self.codexSettingsRefreshingAccountIDs.subtract(batchIDs)
        }
    }
}
