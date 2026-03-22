import CodexBarCore
import Foundation

extension UsageStore {
    func limitedTokenAccounts(
        _ accounts: [ProviderTokenAccount],
        selected: ProviderTokenAccount?) -> [ProviderTokenAccount]
    {
        let limit = 6
        if accounts.count <= limit { return accounts }
        var limited = Array(accounts.prefix(limit))
        if let selected, !limited.contains(where: { $0.id == selected.id }) {
            limited.removeLast()
            limited.append(selected)
        }
        return limited
    }

    func prioritizedTokenAccounts(
        _ accounts: [ProviderTokenAccount],
        selected: ProviderTokenAccount?) -> [ProviderTokenAccount]
    {
        guard let selected,
              let selectedIndex = accounts.firstIndex(where: { $0.id == selected.id })
        else {
            return accounts
        }
        var prioritized = accounts
        let selectedAccount = prioritized.remove(at: selectedIndex)
        prioritized.insert(selectedAccount, at: 0)
        return prioritized
    }

    struct ResolvedAccountOutcome {
        let snapshot: TokenAccountUsageSnapshot
        let usage: UsageSnapshot?
    }

    func fetchTokenAccountSnapshotsInBatches(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount],
        maxConcurrent: Int) async -> [UUID: TokenAccountUsageSnapshot]
    {
        guard !accounts.isEmpty else { return [:] }
        let batchSize = max(1, maxConcurrent)
        var collected: [UUID: TokenAccountUsageSnapshot] = [:]

        for start in stride(from: 0, to: accounts.count, by: batchSize) {
            let batch = Array(accounts[start..<min(start + batchSize, accounts.count)])
            let outcomeBatch = await withTaskGroup(
                of: (ProviderTokenAccount, ProviderFetchOutcome).self,
                returning: [(ProviderTokenAccount, ProviderFetchOutcome)].self)
            { group in
                for account in batch {
                    group.addTask {
                        let override = TokenAccountOverride(provider: provider, account: account)
                        let outcome = await self.fetchOutcome(provider: provider, override: override)
                        return (account, outcome)
                    }
                }

                var results: [(ProviderTokenAccount, ProviderFetchOutcome)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            for (account, outcome) in outcomeBatch {
                let resolved = self.resolveAccountOutcome(outcome, provider: provider, account: account)
                collected[account.id] = resolved.snapshot
            }
        }

        return collected
    }

    func resolveAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> ResolvedAccountOutcome
    {
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let labeled = self.applyAccountLabel(scoped, provider: provider, account: account)
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: labeled,
                error: nil,
                sourceLabel: result.sourceLabel)
            return ResolvedAccountOutcome(snapshot: snapshot, usage: labeled)
        case let .failure(error):
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: nil,
                error: error.localizedDescription,
                sourceLabel: nil)
            return ResolvedAccountOutcome(snapshot: snapshot, usage: nil)
        }
    }
}
