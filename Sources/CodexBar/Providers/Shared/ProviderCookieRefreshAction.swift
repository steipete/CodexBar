import CodexBarCore
import Foundation

@MainActor
enum ProviderCookieRefreshAction {
    enum Outcome: Equatable {
        case refreshed
        case failed
    }

    static func descriptor(
        provider: UsageProvider,
        cookieSource: @escaping () -> ProviderCookieSource,
        context: ProviderSettingsContext) -> ProviderSettingsActionDescriptor
    {
        ProviderSettingsActionDescriptor(
            id: "\(provider.rawValue)-reimport-cookie",
            title: "Refresh",
            style: .bordered,
            isVisible: { cookieSource() == .auto },
            perform: {
                await self.perform(provider: provider, context: context)
            })
    }

    static func trailingText(
        provider: UsageProvider,
        cookieSource: ProviderCookieSource,
        context: ProviderSettingsContext) -> String?
    {
        guard cookieSource != .manual else { return nil }
        return context.statusText(self.statusID(provider)) ?? ProviderCookieSourceUI
            .cachedTrailingText(provider: provider)
    }

    static func refresh(
        provider: UsageProvider,
        operation: () async -> Bool) async -> Outcome
    {
        await ProviderInteractionContext.$current.withValue(.userInitiated) {
            guard let gate = CookieHeaderCache.beginRefreshReadSuppression(provider: provider) else {
                return .failed
            }
            defer { CookieHeaderCache.endRefreshReadSuppression(gate) }

            let validated = await operation()
            guard validated, !Task.isCancelled else { return .failed }

            let commit = CookieHeaderCache.commitRefreshReadSuppression(gate)
            guard commit.stagedCount > 0,
                  commit.committedCount == commit.stagedCount,
                  commit.failedCount == 0
            else { return .failed }
            return .refreshed
        }
    }

    private static func perform(provider: UsageProvider, context: ProviderSettingsContext) async {
        context.setStatusText(self.statusID(provider), L("Refreshing"))
        let previousUpdatedAt = context.store.snapshot(for: provider)?.updatedAt
        let outcome = await self.refresh(provider: provider) {
            await context.store.refreshProvider(provider, allowDisabled: true)
            guard context.store.error(for: provider) == nil,
                  context.store.lastSourceLabels[provider] == "web",
                  let updatedAt = context.store.snapshot(for: provider)?.updatedAt
            else { return false }
            return previousUpdatedAt.map { updatedAt != $0 } ?? true
        }
        context.setStatusText(self.statusID(provider), outcome == .refreshed ? nil : L("Failed"))
    }

    private static func statusID(_ provider: UsageProvider) -> String {
        "\(provider.rawValue)-cookie-refresh-status"
    }
}
