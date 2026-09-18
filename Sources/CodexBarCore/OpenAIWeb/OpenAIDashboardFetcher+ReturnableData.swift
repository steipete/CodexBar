#if os(macOS)
import Foundation

extension OpenAIDashboardFetcher {
    struct ReturnableDashboardDataInput {
        let codeReview: Double?
        let events: [CreditEvent]
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let hasUsageLimits: Bool
        let creditsRemaining: Double?
        var creditsAvailable: Bool?
        let codexCreditLimit: CodexCreditLimitSnapshot?
    }

    nonisolated static func hasReturnableDashboardData(_ input: ReturnableDashboardDataInput) -> Bool {
        input.codeReview != nil
            || !input.events.isEmpty
            || !input.usageBreakdown.isEmpty
            || input.hasUsageLimits
            || input.creditsRemaining != nil
            || input.creditsAvailable == true
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

    nonisolated static func shouldWaitForPageIdentity(
        verifiedSignedInEmail: String?, pageSignedInEmail: String?) -> Bool
    {
        CodexIdentityResolver.normalizeEmail(verifiedSignedInEmail) != nil
            && CodexIdentityResolver.normalizeEmail(pageSignedInEmail) == nil
    }

    nonisolated static func snapshotForUnpairedPage(
        apiData: DashboardAPIData?,
        verifiedSignedInEmail: String?,
        pageSignedInEmail: String?,
        subscriptionResult: OpenAISubscriptionFetchResult = .unavailable,
        previous: OpenAIDashboardSnapshot?) throws -> OpenAIDashboardSnapshot?
    {
        guard let apiData,
              let verifiedSignedInEmail,
              !verifiedSignedInEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let pageSignedInEmail,
              !pageSignedInEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !self.dashboardEmailsMatch(verifiedSignedInEmail, pageSignedInEmail)
        else { return nil }
        guard apiData.hasUsageData else {
            throw FetchError.noDashboardData(body: "Dashboard page identity does not match the authenticated session.")
        }
        return self.snapshotByMergingAPI(
            apiData: apiData,
            verifiedEmail: verifiedSignedInEmail,
            subscriptionResult: subscriptionResult,
            previous: previous)
    }

    nonisolated static func snapshotByMergingAPI(
        apiData: DashboardAPIData,
        verifiedEmail: String,
        subscriptionResult: OpenAISubscriptionFetchResult = .unavailable,
        previous: OpenAIDashboardSnapshot?,
        updatedAt: Date = Date()) -> OpenAIDashboardSnapshot
    {
        let email = verifiedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = self.dashboardEmailsMatch(email, previous?.signedInEmail)
            && self.dashboardCanReuseSnapshot(previous, accountID: apiData.accountID) ? previous : nil
        let usesAPIBalance = apiData.creditsRemaining != nil || apiData.creditsAvailable != nil
        return OpenAIDashboardSnapshot(
            signedInEmail: email.isEmpty ? nil : email,
            accountID: apiData.accountID,
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
            creditsRemaining: usesAPIBalance ? apiData.creditsRemaining : previous?.creditsRemaining,
            creditsAvailable: apiData.creditsAvailable ?? previous?.creditsAvailable,
            balanceIsWorkspace: usesAPIBalance ? apiData.balanceIsWorkspace : previous?.balanceIsWorkspace,
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
        guard let previous, self.dashboardEmailsMatch(snapshot.signedInEmail, previous.signedInEmail),
              self.dashboardCanReuseSnapshot(previous, accountID: snapshot.accountID)
        else {
            return snapshot
        }
        let usesCurrentBalance = snapshot.creditsRemaining != nil || snapshot.creditsAvailable != nil
        let subscriptionExpiresAt = subscriptionResult.succeeded
            ? snapshot.subscriptionExpiresAt
            : snapshot.subscriptionExpiresAt ?? previous.subscriptionExpiresAt
        let subscriptionRenewsAt = subscriptionResult.succeeded
            ? snapshot.subscriptionRenewsAt
            : snapshot.subscriptionRenewsAt ?? previous.subscriptionRenewsAt
        return OpenAIDashboardSnapshot(
            signedInEmail: snapshot.signedInEmail,
            accountID: snapshot.accountID,
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
            creditsRemaining: usesCurrentBalance ? snapshot.creditsRemaining : previous.creditsRemaining,
            creditsAvailable: snapshot.creditsAvailable ?? previous.creditsAvailable,
            balanceIsWorkspace: usesCurrentBalance ? snapshot.balanceIsWorkspace : previous.balanceIsWorkspace,
            codexCreditLimit: snapshot.codexCreditLimit ?? previous.codexCreditLimit,
            accountPlan: snapshot.accountPlan ?? previous.accountPlan,
            subscriptionExpiresAt: subscriptionExpiresAt,
            subscriptionRenewsAt: subscriptionRenewsAt,
            updatedAt: snapshot.updatedAt)
    }

    private nonisolated static func dashboardCanReuseSnapshot(
        _ previous: OpenAIDashboardSnapshot?, accountID: String?) -> Bool
    {
        guard let previous else { return false }
        let currentID = ManagedCodexAccount.normalizeWorkspaceAccountID(accountID)
        let previousID = ManagedCodexAccount.normalizeWorkspaceAccountID(previous.accountID)
        if previous.requiresWorkspaceBalanceScope {
            return currentID != nil && currentID == previousID
        }
        // Legacy personal dashboards and page-only refreshes predate API account IDs.
        guard let currentID, let previousID else { return true }
        return currentID == previousID
    }

    private nonisolated static func dashboardEmailsMatch(_ first: String?, _ second: String?) -> Bool {
        guard let first = CodexIdentityResolver.normalizeEmail(first) else { return false }
        return first == CodexIdentityResolver.normalizeEmail(second)
    }
}
#endif
