import CodexBarCore
import Foundation

extension UsageStore {
    func refreshProviderStatus(_ provider: UsageProvider) async {
        guard self.settings.statusChecksEnabled else { return }
        guard let meta = self.providerMetadata[provider] else { return }
        let publicationRevision = self.providerPublicationRevision(for: provider)

        do {
            let status: ProviderStatus
            var components: [ProviderStatusComponent]?
            if let override = self._test_providerStatusFetchOverride {
                status = try await override(provider)
            } else if let urlString = meta.statusPageURL, let baseURL = URL(string: urlString) {
                let summary = try await Self.fetchStatusSummary(from: baseURL)
                status = summary.status
                components = summary.components
            } else if let productID = meta.statusWorkspaceProductID {
                status = try await Self.fetchWorkspaceStatus(productID: productID)
            } else {
                return
            }
            guard self.statusRefreshPublicationIsCurrent(publicationRevision, for: provider) else { return }
            self.statuses[provider] = status
            // A component endpoint is best-effort. Preserve the last good list when the
            // overall status succeeds but the component request or decoding fails.
            if let components {
                self.statusComponents[provider] = components
            }
            self.emitProviderStatusHooks(provider: provider, indicator: status.indicator)
        } catch {
            guard self.statusRefreshPublicationIsCurrent(publicationRevision, for: provider) else { return }
            self.recordStartupConnectivityRetryableFailure(error)
            // Keep the previous status to avoid flapping when the API hiccups.
            if self.statuses[provider] == nil {
                self.statuses[provider] = ProviderStatus(
                    indicator: .unknown,
                    description: error.localizedDescription,
                    updatedAt: nil)
            }
        }
    }

    private func statusRefreshPublicationIsCurrent(
        _ publicationRevision: ProviderPublicationRevision,
        for provider: UsageProvider) -> Bool
    {
        self.providerPublicationRevisionIsCurrent(publicationRevision, for: provider) &&
            self.settings.statusChecksEnabled &&
            self.settings.isProviderEnabledCached(
                provider: provider,
                metadataByProvider: self.providerMetadata)
    }
}
