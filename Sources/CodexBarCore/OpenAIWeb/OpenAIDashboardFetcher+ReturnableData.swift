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
        subscription: OpenAISubscriptionMetadata?,
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
            subscriptionExpiresAt: subscription == nil
                ? previous?.subscriptionExpiresAt
                : subscription?.expiresAt,
            subscriptionRenewsAt: subscription == nil
                ? previous?.subscriptionRenewsAt
                : subscription?.renewsAt,
            updatedAt: updatedAt)
    }

    nonisolated static func fillingMissingPageFields(
        _ snapshot: OpenAIDashboardSnapshot,
        from previous: OpenAIDashboardSnapshot?,
        subscription: OpenAISubscriptionMetadata? = nil) -> OpenAIDashboardSnapshot
    {
        guard let previous else { return snapshot }
        let subscriptionExpiresAt = subscription == nil
            ? snapshot.subscriptionExpiresAt ?? previous.subscriptionExpiresAt
            : snapshot.subscriptionExpiresAt
        let subscriptionRenewsAt = subscription == nil
            ? snapshot.subscriptionRenewsAt ?? previous.subscriptionRenewsAt
            : snapshot.subscriptionRenewsAt
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
