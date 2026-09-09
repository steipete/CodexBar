import CodexBarCore
import Foundation

@MainActor
enum ProviderCookieRefreshAction {
    enum Outcome: Equatable {
        case refreshed
        case failed
    }

    enum ResultValidation {
        case webSource
        case providerCostBalance
        /// Success requires both the Web source and a prepaid wallet balance, so an explicit browser
        /// refresh can validate a Hugging Face wallet without composing it into an API billing snapshot.
        case webProviderCostBalance
    }

    @TaskLocal static var isRefreshingCookie = false

    static func descriptor(
        provider: UsageProvider,
        cookieSource: @escaping () -> ProviderCookieSource,
        additionalVisibility: @escaping () -> Bool = { true },
        resultValidation: ResultValidation = .webSource,
        sourceModeOverride: ProviderSourceMode? = nil,
        followUpWithOrdinaryRefresh: Bool = false,
        context: ProviderSettingsContext) -> ProviderSettingsActionDescriptor
    {
        ProviderSettingsActionDescriptor(
            id: "\(provider.rawValue)-reimport-cookie",
            title: "Refresh",
            style: .bordered,
            isVisible: { cookieSource() == .auto && additionalVisibility() },
            perform: {
                await ProviderSettingsRefreshInteraction.perform {
                    await self.perform(
                        provider: provider,
                        resultValidation: resultValidation,
                        sourceModeOverride: sourceModeOverride,
                        followUpWithOrdinaryRefresh: followUpWithOrdinaryRefresh,
                        context: context)
                }
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
        await self.$isRefreshingCookie.withValue(true) {
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
    }

    private static func perform(
        provider: UsageProvider,
        resultValidation: ResultValidation,
        sourceModeOverride: ProviderSourceMode?,
        followUpWithOrdinaryRefresh: Bool,
        context: ProviderSettingsContext) async
    {
        context.setStatusText(self.statusID(provider), L("Refreshing"))
        let previousUpdatedAt = context.store.snapshot(for: provider.instanceID)?.updatedAt
        let outcome = await self.refresh(provider: provider) {
            await context.store.refreshProvider(
                provider,
                allowDisabled: true,
                sourceModeOverride: sourceModeOverride)
            return self.resultIsValid(
                provider: provider,
                validation: resultValidation,
                previousUpdatedAt: previousUpdatedAt,
                context: context)
        }
        guard outcome == .refreshed else {
            context.setStatusText(self.statusID(provider), L("Failed"))
            return
        }
        if followUpWithOrdinaryRefresh {
            // Provider-specific by design (FP-194): Hugging Face validated the Web wallet in
            // isolation; once the staged cookies have committed, one best-effort ordinary Auto
            // refresh restores the composed API-spend-plus-wallet snapshot immediately. A broken
            // API credential must not turn the successful Cookie Refresh into a failure.
            await context.store.refreshProvider(provider, allowDisabled: true)
        }
        context.setStatusText(self.statusID(provider), nil)
    }

    private static func resultIsValid(
        provider: UsageProvider,
        validation: ResultValidation,
        previousUpdatedAt: Date?,
        context: ProviderSettingsContext) -> Bool
    {
        guard context.store.error(for: provider) == nil,
              let snapshot = context.store.snapshot(for: provider.instanceID),
              previousUpdatedAt.map({ snapshot.updatedAt != $0 }) ?? true
        else { return false }

        switch validation {
        case .webSource:
            return context.store.lastSourceLabels[provider.instanceID] == "web"
        case .providerCostBalance:
            return snapshot.providerCost?.balance != nil
        case .webProviderCostBalance:
            return context.store.lastSourceLabels[provider.instanceID] == "web" &&
                snapshot.providerCost?.balance != nil
        }
    }

    private static func statusID(_ provider: UsageProvider) -> String {
        "\(provider.rawValue)-cookie-refresh-status"
    }
}
