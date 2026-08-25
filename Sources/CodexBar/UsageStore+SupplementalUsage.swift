import CodexBarCore
import Foundation

extension UsageStore {
    func scheduleSupplementalUsageUpdate(
        provider: UsageProvider,
        result: ProviderFetchResult,
        generation: UInt64?,
        accountID: UUID?)
    {
        guard let sourceTask = result.supplementalUsageTask else { return }

        let expectedUpdatedAt = result.usage.updatedAt
        Task { @MainActor [weak self] in
            let update = await sourceTask.value
            guard let self else { return }
            guard self.isCurrentProviderRefreshGeneration(provider, generation: generation)
            else { return }
            self.applySupplementalUsageUpdate(
                update,
                provider: provider,
                expectedUpdatedAt: expectedUpdatedAt,
                accountID: accountID)
        }
    }

    private func applySupplementalUsageUpdate(
        _ update: ProviderSupplementalUsageUpdate,
        provider: UsageProvider,
        expectedUpdatedAt: Date,
        accountID: UUID?)
    {
        guard provider == .grok,
              let current = self.snapshots[provider.instanceID],
              current.updatedAt == expectedUpdatedAt
        else { return }

        let resetCredits: GrokRateLimitResetCreditsSnapshot? = switch update {
        case let .grokResetCredits(snapshot): snapshot
        }
        let updated = current.withGrokResetCredits(resetCredits)
        self.snapshots[provider.instanceID] = updated
        if self.lastKnownResetSnapshots[provider.instanceID]?.updatedAt == expectedUpdatedAt {
            self.lastKnownResetSnapshots[provider.instanceID] = updated
        }

        guard let accountID,
              let account = self.uniqueTokenAccount(provider: provider, accountID: accountID)
        else { return }
        self.cacheTokenAccountSnapshot(
            provider: provider,
            account: account,
            snapshot: updated,
            sourceLabel: self.lastSourceLabels[provider.instanceID])
    }
}
