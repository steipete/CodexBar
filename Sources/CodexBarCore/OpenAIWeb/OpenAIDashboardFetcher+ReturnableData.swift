#if os(macOS)
import Foundation

extension OpenAIDashboardFetcher {
    struct ReturnableDashboardDataInput {
        let codeReview: Double?
        let events: [CreditEvent]
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let hasUsageLimits: Bool
        let creditsRemaining: Double?
        let codexCreditLimit: CodexCreditLimitSnapshot?
    }

    nonisolated static func hasReturnableDashboardData(_ input: ReturnableDashboardDataInput) -> Bool {
        input.codeReview != nil
            || !input.events.isEmpty
            || !input.usageBreakdown.isEmpty
            || input.hasUsageLimits
            || input.creditsRemaining != nil
            || input.codexCreditLimit != nil
    }

    nonisolated static func hasAnyDashboardSignal(
        hasReturnableData: Bool,
        creditsHeaderPresent: Bool) -> Bool
    {
        hasReturnableData || creditsHeaderPresent
    }

    /// Skip the hidden ChatGPT WebView unless the caller asked for a DOM scrape.
    nonisolated static func shouldSkipPageScrape(allowPageScrape: Bool) -> Bool {
        !allowPageScrape
    }

    nonisolated static func snapshotByMergingAPI(
        apiData: DashboardAPIData,
        verifiedEmail: String,
        subscriptionResult: OpenAISubscriptionFetchResult = .unavailable,
        previous: OpenAIDashboardSnapshot?,
        updatedAt: Date = Date()) -> OpenAIDashboardSnapshot
    {
        let email = verifiedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAIDashboardSnapshot(
            signedInEmail: email.isEmpty ? previous?.signedInEmail : email,
            codeReviewRemainingPercent: previous?.codeReviewRemainingPercent,
            codeReviewLimit: previous?.codeReviewLimit,
            creditEvents: previous?.creditEvents ?? [],
            dailyBreakdown: previous?.dailyBreakdown ?? [],
            usageBreakdown: previous?.usageBreakdown ?? [],
            creditsPurchaseURL: previous?.creditsPurchaseURL,
            primaryLimit: apiData.primaryLimit ?? previous?.primaryLimit,
            secondaryLimit: apiData.secondaryLimit ?? previous?.secondaryLimit,
            extraRateWindows: apiData.extraRateWindows.isEmpty
                ? previous?.extraRateWindows
                : apiData.extraRateWindows,
            creditsRemaining: apiData.creditsRemaining ?? previous?.creditsRemaining,
            codexCreditLimit: apiData.codexCreditLimit ?? previous?.codexCreditLimit,
            // Prefer the page-derived plan (more specific, e.g. Pro Lite) over the generic API plan_type.
            accountPlan: previous?.accountPlan ?? apiData.accountPlan,
            subscriptionExpiresAt: subscriptionResult.succeeded
                ? subscriptionResult.metadata?.expiresAt
                : previous?.subscriptionExpiresAt,
            subscriptionRenewsAt: subscriptionResult.succeeded
                ? subscriptionResult.metadata?.renewsAt
                : previous?.subscriptionRenewsAt,
            updatedAt: updatedAt)
    }

    nonisolated static func fillingMissingPageFields(
        _ snapshot: OpenAIDashboardSnapshot,
        from previous: OpenAIDashboardSnapshot?,
        subscriptionResult: OpenAISubscriptionFetchResult = .unavailable) -> OpenAIDashboardSnapshot
    {
        guard let previous else { return snapshot }
        let subscriptionExpiresAt = subscriptionResult.succeeded
            ? snapshot.subscriptionExpiresAt
            : snapshot.subscriptionExpiresAt ?? previous.subscriptionExpiresAt
        let subscriptionRenewsAt = subscriptionResult.succeeded
            ? snapshot.subscriptionRenewsAt
            : snapshot.subscriptionRenewsAt ?? previous.subscriptionRenewsAt
        return OpenAIDashboardSnapshot(
            signedInEmail: snapshot.signedInEmail ?? previous.signedInEmail,
            codeReviewRemainingPercent: snapshot.codeReviewRemainingPercent
                ?? previous.codeReviewRemainingPercent,
            codeReviewLimit: snapshot.codeReviewLimit ?? previous.codeReviewLimit,
            creditEvents: snapshot.creditEvents.isEmpty ? previous.creditEvents : snapshot.creditEvents,
            dailyBreakdown: snapshot.dailyBreakdown.isEmpty ? previous.dailyBreakdown : snapshot.dailyBreakdown,
            usageBreakdown: snapshot.usageBreakdown.isEmpty ? previous.usageBreakdown : snapshot.usageBreakdown,
            creditsPurchaseURL: snapshot.creditsPurchaseURL ?? previous.creditsPurchaseURL,
            primaryLimit: snapshot.primaryLimit ?? previous.primaryLimit,
            secondaryLimit: snapshot.secondaryLimit ?? previous.secondaryLimit,
            extraRateWindows: snapshot.extraRateWindows ?? previous.extraRateWindows,
            creditsRemaining: snapshot.creditsRemaining ?? previous.creditsRemaining,
            codexCreditLimit: snapshot.codexCreditLimit ?? previous.codexCreditLimit,
            accountPlan: snapshot.accountPlan ?? previous.accountPlan,
            subscriptionExpiresAt: subscriptionExpiresAt,
            subscriptionRenewsAt: subscriptionRenewsAt,
            updatedAt: snapshot.updatedAt)
    }
}
#endif
