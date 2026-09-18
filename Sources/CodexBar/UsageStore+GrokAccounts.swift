import CodexBarCore
import Foundation

extension UsageStore {
    func shouldFetchAllGrokVisibleAccounts() -> Bool {
        self.settings.multiAccountMenuLayout == .stacked &&
            self.settings.grokVisibleAccountProjection.visibleAccounts.count > 1
    }

    func activateCachedGrokAccountSnapshot(visibleAccountID: String) {
        guard self.settings.grokVisibleAccountProjection.activeVisibleAccountID == visibleAccountID else { return }
        guard let cached = self.grokAccountSnapshots.first(where: { $0.id == visibleAccountID }) else {
            self.snapshots[.grok] = nil
            self.errors[.grok] = nil
            self.lastSourceLabels[.grok] = nil
            return
        }
        self.snapshots[.grok] = cached.snapshot
        self.errors[.grok] = cached.error
        if let snapshot = cached.snapshot {
            self.lastKnownResetSnapshots[.grok] = snapshot
        }
        self.lastSourceLabels[.grok] = cached.sourceLabel
    }

    func refreshGrokVisibleAccountsForMenu(generation: UInt64? = nil) async {
        let projection = self.settings.grokVisibleAccountProjection
        let accounts = projection.visibleAccounts
        guard accounts.count > 1 else {
            self.grokAccountSnapshots = []
            return
        }

        let originalVisibleAccountID = projection.activeVisibleAccountID
        let priorSnapshots = self.grokAccountSnapshots
        var snapshots: [GrokAccountUsageSnapshot] = []
        var selectedOutcome: ProviderFetchOutcome?
        var selectedSnapshot: UsageSnapshot?

        let results = await self.fetchGrokVisibleAccountOutcomes(accounts)
        guard !Task.isCancelled,
              self.isCurrentProviderRefreshGeneration(.grok, generation: generation)
        else { return }

        let currentProjection = self.settings.grokVisibleAccountProjection
        for result in results {
            let account = currentProjection.account(id: result.account.id) ?? result.account
            let prior = priorSnapshots.first { $0.id == account.id }
            switch result.outcome.result {
            case let .success(fetchResult):
                let fetched = fetchResult.usage.scoped(to: .grok)
                guard GrokFetchedAccountIdentity.matches(
                    fetched.accountEmail(for: .grok),
                    storedEmail: account.email)
                else {
                    snapshots.append(GrokAccountUsageSnapshot(
                        account: account,
                        snapshot: prior?.snapshot,
                        error: L("Grok account identity did not match the selected home."),
                        sourceLabel: prior?.sourceLabel))
                    continue
                }
                let usage = self.relabeledGrokUsage(fetched, account: account)
                snapshots.append(GrokAccountUsageSnapshot(
                    account: account,
                    snapshot: usage,
                    error: nil,
                    sourceLabel: fetchResult.sourceLabel))
                if account.id == originalVisibleAccountID {
                    selectedOutcome = result.outcome
                    selectedSnapshot = usage
                }
            case let .failure(error):
                snapshots.append(GrokAccountUsageSnapshot(
                    account: account,
                    snapshot: prior?.snapshot,
                    error: error.localizedDescription,
                    sourceLabel: prior?.sourceLabel))
                if account.id == originalVisibleAccountID {
                    selectedOutcome = result.outcome
                    selectedSnapshot = prior?.snapshot
                }
            }
        }

        self.grokAccountSnapshots = snapshots
        if let selectedOutcome {
            await self.applySelectedOutcome(
                selectedOutcome,
                provider: .grok,
                account: nil,
                fallbackSnapshot: selectedSnapshot,
                generation: generation)
            if let selectedSnapshot {
                self.snapshots[.grok] = selectedSnapshot
            }
        }
    }

    private func fetchGrokVisibleAccountOutcomes(_ accounts: [GrokVisibleAccount]) async
        -> [(account: GrokVisibleAccount, outcome: ProviderFetchOutcome)]
    {
        var results: [(account: GrokVisibleAccount, outcome: ProviderFetchOutcome)] = []
        for account in accounts {
            let outcome = await self.fetchOutcome(
                provider: .grok,
                override: nil,
                grokActiveSourceOverride: account.selectionSource)
            results.append((account: account, outcome: outcome))
        }
        return results
    }

    private func relabeledGrokUsage(_ usage: UsageSnapshot, account: GrokVisibleAccount) -> UsageSnapshot {
        let scoped = usage.scoped(to: .grok)
        return scoped.withIdentity(ProviderIdentitySnapshot(
            providerID: UsageProvider.grok.instanceID,
            accountEmail: account.email,
            accountOrganization: scoped.accountOrganization(for: .grok),
            loginMethod: scoped.loginMethod(for: .grok)))
    }
}
