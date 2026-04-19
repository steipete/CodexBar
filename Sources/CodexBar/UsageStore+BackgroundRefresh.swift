import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    private func clearProviderState(_ provider: UsageProvider) {
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

    func clearDisabledProviderState(enabledProviders: Set<UsageProvider>) {
        for provider in UsageProvider.allCases where !enabledProviders.contains(provider) {
            self.clearProviderState(provider)
        }
    }

    func clearUnavailableProviderState(
        displayEnabledProviders: Set<UsageProvider>,
        availableProviders: Set<UsageProvider>)
    {
        for provider in displayEnabledProviders where !availableProviders.contains(provider) {
            self.clearProviderState(provider)
        }
    }
}
