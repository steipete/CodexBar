import CodexBarCore
import Foundation

extension StatusItemController {
    func makeMenuCardRefreshMonitor() -> MenuCardRefreshMonitor {
        MenuCardRefreshMonitor(
            resolveModel: { [weak self] provider in
                self?.menuCardModel(for: provider)
            },
            isProviderRefreshActive: { [weak self] provider in
                self?.store.refreshingProviders.contains(provider.instanceID) == true
            })
    }

    func menuCardModel(
        for provider: UsageProvider?,
        context: UsageMenuCardContext = .menu) -> UsageMenuCardView.Model?
    {
        // Provider-specific by design: Codex is the historical fallback when no provider is enabled.
        let target = provider ?? self.store.enabledFirstPartyProvidersForDisplay().first ?? .codex
        return self.store.menuCardModel(for: target, context: context)
    }

    func accountInfo(for account: CodexVisibleAccount) -> AccountInfo {
        AccountInfo(email: account.email, plan: account.workspaceLabel)
    }
}
