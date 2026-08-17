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
        additionalVisibility: @escaping () -> Bool = { true },
        suppressCachedCookies: Bool = true,
        context: ProviderSettingsContext) -> ProviderSettingsActionDescriptor
    {
        ProviderSettingsActionDescriptor(
            id: "\(provider.rawValue)-reimport-cookie",
            title: "Refresh",
            style: .bordered,
            isVisible: { cookieSource() == .auto && additionalVisibility() },
            perform: {
                await self.perform(
                    provider: provider,
                    suppressCachedCookies: suppressCachedCookies,
                    context: context)
            })
    }

    static func trailingText(
        provider: UsageProvider,
        cookieSource: ProviderCookieSource,
        context: ProviderSettingsContext) -> String?
    {
        guard cookieSource != .manual else { return nil }
        return context.statusText(self.statusID(provider))
            ?? ProviderCookieSourceUI
            .cachedTrailingText(provider: provider)
    }

    static func refresh(
        provider: UsageProvider,
        suppressCachedCookies: Bool = true,
        operation: () async -> Bool) async -> Outcome
    {
        await BrowserCookieAccessGate.withExplicitRetry {
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                if !suppressCachedCookies {
                    let validated = await operation()
                    return validated && !Task.isCancelled ? .refreshed : .failed
                }

                guard let gate = CookieHeaderCache.beginRefreshReadSuppression(provider: provider)
                else {
                    return .failed
                }
                defer { CookieHeaderCache.endRefreshReadSuppression(gate) }

                let validated = await operation()
                guard validated, !Task.isCancelled else { return .failed }

                let commit = CookieHeaderCache.commitRefreshReadSuppression(gate)
                if commit.stagedCount == 0 {
                    return .refreshed
                }
                guard commit.committedCount == commit.stagedCount, commit.failedCount == 0 else {
                    return .failed
                }
                return .refreshed
            }
        }
    }

    private static func perform(
        provider: UsageProvider,
        suppressCachedCookies: Bool,
        context: ProviderSettingsContext) async
    {
        context.setStatusText(self.statusID(provider), L("Refreshing"))
        let outcome = await self.refresh(
            provider: provider,
            suppressCachedCookies: suppressCachedCookies)
        {
            await context.store.refreshProvider(provider, allowDisabled: true)
            return context.store.error(for: provider) == nil
                && context.store.snapshot(for: provider.instanceID) != nil
        }
        context.setStatusText(self.statusID(provider), outcome == .refreshed ? nil : L("Failed"))
    }

    private static func statusID(_ provider: UsageProvider) -> String {
        "\(provider.rawValue)-cookie-refresh-status"
    }
}
