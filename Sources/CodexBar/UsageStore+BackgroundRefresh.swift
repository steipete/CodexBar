import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func clearDisabledProviderState(enabledProviders: Set<UsageProvider>) {
        for provider in UsageProvider.allCases where !enabledProviders.contains(provider) {
            self.refreshingProviders.remove(provider)
            self.snapshots.removeValue(forKey: provider)
            self.errors[provider] = nil
            self.lastSourceLabels.removeValue(forKey: provider)
            self.lastFetchAttempts.removeValue(forKey: provider)
            self.accountSnapshots.removeValue(forKey: provider)
            self.tokenSnapshots.removeValue(forKey: provider)
            self.tokenErrors[provider] = nil
            self.failureGates[provider]?.reset()
            self.tokenFailureGates[provider]?.reset()
            self.statuses.removeValue(forKey: provider)
            self.lastKnownSessionRemaining.removeValue(forKey: provider)
            self.lastKnownSessionWindowSource.removeValue(forKey: provider)
            self.lastTokenFetchAt.removeValue(forKey: provider)
        }
    }
}
